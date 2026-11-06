#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# Obsidian LiveSync Server (CouchDB) – start script
#
# Flow:
#   1. Read the configuration from /data/options.json
#   2. Refuse to start if plain HTTP (5984) is published on the host
#   3. Create the data directories and hand them to uid 5984
#   4. Copy the TLS certificate (option ssl) and write the local.d
#      configuration on EVERY start
#   5. Start CouchDB as the couchdb user
#   6. Wait for /_up (and the HTTPS listener), create the database, verify
#      that auth is enforced
#   7. Supervise the process, stop cleanly on SIGTERM
#
# Four pitfalls of the CouchDB image, all of them hit during the proof of
# concept:
#
#   a) Configuration set through the REST API lands in the container's write
#      layer, not under /data. An add-on update rebuilds the container and
#      discards it — including require_valid_user, which would leave the
#      database open to anyone on the network. Hence step 3 on EVERY start.
#   b) The local.d file must be writable. Otherwise the image's entrypoint
#      fails on a chmod, and it fails silently (set -e plus "chmod -f"): the
#      container exits with code 1 and an empty log.
#   c) local.d must not be mounted as a directory; CouchDB has to be able to
#      create files inside it.
#   d) /_up answers 401 as soon as require_valid_user applies. The watchdog
#      cannot send credentials, so require_valid_user_except_for_up is needed.
# ==============================================================================

set -euo pipefail

# ─── Helper: read a configuration value ───────────────────────────────────────
# Same approach as the SilverBullet add-on: bashio first, the file as a
# fallback, so the script can also be tested locally without a Supervisor.
get_config_value() {
    local key="$1" default="${2:-}" value=""

    value=$(bashio::config "$key" 2>/dev/null) || value=""

    if [[ -z "$value" || "$value" == "null" ]] && [[ -f /data/options.json ]]; then
        value=$(jq -r ".${key} // empty" /data/options.json 2>/dev/null || true)
    fi

    if [[ -z "$value" && -n "$default" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

log_info()  { bashio::log.info "$@" 2>/dev/null || echo "[INFO]  $*"; }
log_warn()  { bashio::log.warning "$@" 2>/dev/null || echo "[WARN]  $*"; }
log_fatal() { bashio::log.fatal "$@" 2>/dev/null || echo "[FATAL] $*" >&2; }

# ─── Helper: refuse a published plain-HTTP port ───────────────────────────────
# Asks the Supervisor which host port, if any, the given container port is
# published on, and stops the add-on if it is published at all. Fails closed:
# if the Supervisor cannot be asked, the add-on does not start either. Outside
# a Supervisor (no SUPERVISOR_TOKEN, e.g. a local docker run) it only warns.
require_unpublished_port() {
    local port_key="$1" info="" attempt published

    if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
        log_warn "No Supervisor connection: cannot check whether ${port_key}"
        log_warn "is published. Never publish it on the host."
        return 0
    fi

    for attempt in 1 2 3; do
        if info=$(curl -sf --max-time 5 \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                http://supervisor/addons/self/info); then
            break
        fi
        info=""
        if [[ ${attempt} -lt 3 ]]; then
            sleep 2
        fi
    done

    if [[ -z "${info}" ]] || [[ "$(jq -r '.result // empty' <<< "${info}" 2>/dev/null)" != "ok" ]]; then
        log_fatal "Could not ask the Supervisor whether ${port_key} is published."
        log_fatal "Not starting rather than risking plain HTTP on the network."
        exit 1
    fi

    published=$(jq -r --arg k "${port_key}" '.data.network[$k] // empty' <<< "${info}" 2>/dev/null) \
        || published="unknown"
    if [[ -n "${published}" ]]; then
        log_fatal "${port_key} is published on host port ${published}."
        log_fatal "That port speaks plain HTTP, so every login would cross the"
        log_fatal "network in clear text. Clear it under Settings -> Add-ons ->"
        log_fatal "this add-on -> Network, and connect over HTTPS instead"
        log_fatal "(option ssl, port 6984). See the documentation."
        exit 1
    fi
}

# ─── Helper: validate a file name under /ssl ──────────────────────────────────
# Relative names only, no ".." segment, nothing that could start an option.
valid_ssl_name() {
    local name="$1"
    [[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$ ]] || return 1
    [[ "/${name}/" != */../* ]] || return 1
}

# ─── Read the configuration ───────────────────────────────────────────────────
log_info "Starting the Obsidian LiveSync Server add-on..."

ADMIN_USER=$(get_config_value 'admin_user' 'obsidian')
ADMIN_PASSWORD=$(get_config_value 'admin_password')
DATABASE=$(get_config_value 'database' 'obsidian')
CORS_ORIGINS=$(get_config_value 'cors_origins' 'app://obsidian.md,capacitor://localhost,http://localhost')
CORS_HEADERS_EXTRA=$(get_config_value 'cors_headers' '')
SSL=$(get_config_value 'ssl' 'false')
CERTFILE=$(get_config_value 'certfile' 'fullchain.pem')
KEYFILE=$(get_config_value 'keyfile' 'privkey.pem')
LOG_LEVEL=$(get_config_value 'log_level' 'warning')

# Plain HTTP must never reach the LAN. Checked before anything else starts.
require_unpublished_port "5984/tcp"

if [[ -z "${ADMIN_PASSWORD}" ]]; then
    log_fatal "admin_password is empty."
    log_fatal "CouchDB is never started without an administrator password:"
    log_fatal "without one it runs in admin party mode and everyone on the"
    log_fatal "network may write."
    exit 1
fi

if [[ ${#ADMIN_PASSWORD} -lt 12 ]]; then
    log_warn "The administrator password is shorter than 12 characters."
fi

# Extra request headers a client may send (for example a proxy token set under
# "Custom Headers" in the plugin). CouchDB answers the CORS preflight for any
# header outside its list with the normal 401, so the headers must be listed.
# The value goes into an ini file, so only plain header names are accepted.
CORS_HEADERS_LINE=""
if [[ -n "${CORS_HEADERS_EXTRA}" ]]; then
    if [[ ! "${CORS_HEADERS_EXTRA}" =~ ^[A-Za-z0-9-]+(,[[:space:]]*[A-Za-z0-9-]+)*$ ]]; then
        log_fatal "cors_headers must be a comma-separated list of header names"
        log_fatal "(letters, digits and hyphens only)."
        exit 1
    fi
    CORS_HEADERS_EXTRA=$(printf '%s' "${CORS_HEADERS_EXTRA,,}" | tr -d '[:space:]' | sed 's/,/, /g')
    CORS_HEADERS_LINE="headers = accept, authorization, content-type, origin, referer, ${CORS_HEADERS_EXTRA}"
fi

log_info "Administrator: ${ADMIN_USER}"
log_info "Database: ${DATABASE}"

# ─── Data directories ─────────────────────────────────────────────────────────
# Under /data, so the database is part of the add-on backup. The files must be
# owned by uid 5984 or CouchDB cannot write.
DATA_DIR=/data/couchdb
VIEW_DIR=/data/couchdb-views
CONFIG_FILE=/opt/couchdb/etc/local.d/10-addon.ini

mkdir -p "${DATA_DIR}" "${VIEW_DIR}"
chown -R 5984:5984 "${DATA_DIR}" "${VIEW_DIR}"

# ─── TLS certificate ──────────────────────────────────────────────────────────
# CouchDB runs as uid 5984 and has to read the key, but /ssl is shared with
# other add-ons. Only the two named files are copied into the container (not
# under /data, so the key is not part of the add-on backup), and the copy is
# rebuilt on every start, also removed when ssl is off.
TLS_DIR=/opt/couchdb/etc/tls
rm -rf "${TLS_DIR}"
SSL_BLOCK=""
if [[ "${SSL}" == "true" ]]; then
    for name in "${CERTFILE}" "${KEYFILE}"; do
        if ! valid_ssl_name "${name}"; then
            log_fatal "certfile and keyfile must be file names relative to /ssl,"
            log_fatal "without '..' (got: '${name}')."
            exit 1
        fi
        if [[ ! -r "/ssl/${name}" ]]; then
            log_fatal "/ssl/${name} does not exist or cannot be read."
            log_fatal "Put the certificate and key into /ssl, or turn ssl off."
            exit 1
        fi
    done
    install -d -o 5984 -g 5984 -m 0700 "${TLS_DIR}"
    install -o 5984 -g 5984 -m 0644 "/ssl/${CERTFILE}" "${TLS_DIR}/cert.pem"
    install -o 5984 -g 5984 -m 0600 "/ssl/${KEYFILE}" "${TLS_DIR}/key.pem"
    SSL_BLOCK="[ssl]
enable = true
port = 6984
cert_file = ${TLS_DIR}/cert.pem
key_file = ${TLS_DIR}/key.pem"
    log_info "HTTPS is on: /ssl/${CERTFILE}, port 6984."
fi

# ─── Write the configuration (pitfall a) ──────────────────────────────────────
# Everything that has to survive a container rebuild lives here, not only in
# the REST state. The password goes into [admins] in clear text; CouchDB
# replaces it with a hash on the first start and writes the file back while
# doing so, which is why it has to be writable (pitfall b).
mkdir -p /opt/couchdb/etc/local.d
cat > "${CONFIG_FILE}" <<INI
; Rewritten by run.sh on every start. Editing it by hand has no effect.
[couchdb]
database_dir = ${DATA_DIR}
view_index_dir = ${VIEW_DIR}
single_node = true
max_document_size = 50000000

[chttpd]
; 0.0.0.0 inside the container: the MCP add-on reaches CouchDB over the
; internal add-on network. The host never publishes this port (see above).
bind_address = 0.0.0.0
port = 5984
require_valid_user = true
; Only /_up stays reachable without credentials, so that the watchdog and the
; health check keep working (pitfall d).
require_valid_user_except_for_up = true
enable_cors = true
max_http_request_size = 4294967296

[chttpd_auth]
require_valid_user = true

[httpd]
; In CouchDB 3 CORS belongs in both sections.
enable_cors = true
WWW-Authenticate = Basic realm="couchdb"

[cors]
credentials = true
origins = ${CORS_ORIGINS}
max_age = 3600
${CORS_HEADERS_LINE}

[log]
level = ${LOG_LEVEL}

${SSL_BLOCK}

[admins]
${ADMIN_USER} = ${ADMIN_PASSWORD}
INI

chown 5984:5984 "${CONFIG_FILE}"
chmod 0644 "${CONFIG_FILE}"
log_info "Configuration written: ${CONFIG_FILE}"

# ─── Start CouchDB ────────────────────────────────────────────────────────────
export HOME=/opt/couchdb
log_info "Starting CouchDB on port 5984..."

setpriv --reuid=couchdb --regid=couchdb --clear-groups \
    /opt/couchdb/bin/couchdb &
COUCHDB_PID=$!

cleanup() {
    local exit_code=${1:-0}
    log_info "Stopping the add-on..."
    if [[ -n "${COUCHDB_PID:-}" ]] && kill -0 "${COUCHDB_PID}" 2>/dev/null; then
        kill -TERM "${COUCHDB_PID}" 2>/dev/null || true
        wait "${COUCHDB_PID}" 2>/dev/null || true
    fi
    log_info "CouchDB shut down cleanly."
    exit "${exit_code}"
}
trap cleanup TERM INT

# ─── Wait until ready ─────────────────────────────────────────────────────────
# Thanks to require_valid_user_except_for_up, /_up needs no credentials.
log_info "Waiting for CouchDB..."
MAX_WAIT=120
ELAPSED=0
until curl -sf http://127.0.0.1:5984/_up > /dev/null 2>&1; do
    if ! kill -0 "${COUCHDB_PID}" 2>/dev/null; then
        log_fatal "CouchDB exited unexpectedly."
        exit 1
    fi
    ELAPSED=$((ELAPSED + 2))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        log_fatal "CouchDB did not respond within ${MAX_WAIT}s."
        kill "${COUCHDB_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done
log_info "CouchDB is ready."

# With ssl on, the HTTPS listener has to come up too. Otherwise Obsidian could
# not connect at all, and nobody should be tempted to publish 5984 instead.
if [[ "${SSL}" == "true" ]]; then
    ELAPSED=0
    until curl -sfk https://127.0.0.1:6984/_up > /dev/null 2>&1; do
        ELAPSED=$((ELAPSED + 2))
        if [[ ${ELAPSED} -ge 30 ]]; then
            log_fatal "The HTTPS listener on 6984 did not come up within 30s."
            log_fatal "Check that certfile and keyfile are a matching PEM pair."
            cleanup 1
        fi
        sleep 2
    done
    log_info "HTTPS listener is ready on port 6984."
fi

# ─── Provisioning ─────────────────────────────────────────────────────────────
AUTH=(-u "${ADMIN_USER}:${ADMIN_PASSWORD}")
API=http://127.0.0.1:5984

# System databases. single_node = true normally creates them; the call is
# idempotent and does no harm.
for db in _users _replicator; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${AUTH[@]}" "${API}/${db}")
    case "${code}" in
        201|202|412) ;;
        *) log_warn "System database ${db}: HTTP ${code}" ;;
    esac
done

# The vault database. 412 means it already exists.
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${AUTH[@]}" "${API}/${DATABASE}")
case "${code}" in
    201|202) log_info "Database '${DATABASE}' created." ;;
    412)     log_info "Database '${DATABASE}' already exists." ;;
    *)       log_fatal "Could not create the database '${DATABASE}': HTTP ${code}"
             cleanup 1 ;;
esac

# Double-check that the mandatory login really applies. If it does not, the
# database is open — better not to keep running at all.
code=$(curl -s -o /dev/null -w '%{http_code}' "${API}/${DATABASE}")
if [[ "${code}" != "401" ]]; then
    log_fatal "The database is reachable without credentials (HTTP ${code})."
    log_fatal "require_valid_user did not take effect. Stopping the add-on."
    cleanup 1
fi
log_info "Mandatory login is in effect (without credentials: HTTP 401)."

if [[ "${SSL}" == "true" ]]; then
    log_info "LiveSync URL for Obsidian: https://<host-name-in-the-certificate>:6984"
    log_info "Fauxton: https://<host-name-in-the-certificate>:6984/_utils/"
    log_info "Publish 6984/tcp under Network to reach it from the LAN."
else
    log_info "HTTPS is off. Only other add-ons reach CouchDB, over the internal"
    log_info "network (for example http://local-obsidian-couchdb:5984)."
    log_info "To connect Obsidian, turn ssl on or put a TLS proxy add-on in front."
fi

# ─── Supervise the main process ───────────────────────────────────────────────
set +e
wait "${COUCHDB_PID}"
EXIT_CODE=$?
set -e

if [[ ${EXIT_CODE} -ne 0 ]]; then
    log_fatal "CouchDB exited unexpectedly (exit code: ${EXIT_CODE})."
fi
cleanup "${EXIT_CODE}"
