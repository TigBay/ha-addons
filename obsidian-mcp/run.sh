#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# Obsidian MCP Server – start script
#
# Flow:
#   1. Read the configuration from /data/options.json
#   2. Refuse to start on an unsafe configuration (no token, plain-HTTP port
#      8787 published on the host)
#   3. Hand /data to uid 1000 and point DATA_DIR at it
#   4. Wait until CouchDB answers and the database exists
#   5. Start the server as uid 1000, and with ssl on the TLS terminator on
#      8443 in front of it; supervise both, stop cleanly on SIGTERM
#
# Three findings from the proof of concept that shape this script:
#
#   a) COUCHDB_PASSPHRASE has to be present BEFORE the process starts. Started
#      without it against an encrypted vault, the server reports "0 notes" and
#      "ChangeManager Error watching changes" — neither of which names the real
#      cause. The check below fails loudly instead.
#   b) The server stores its search index and its OAuth tokens under
#      $HOME/.obsidian-mcp unless DATA_DIR is set. DATA_DIR is undocumented;
#      it was read out of the bundled code:
#        baseDataDir = process.env.DATA_DIR ?? join(process.env.HOME, ".obsidian-mcp")
#      Without it both are lost on every add-on update, so the index has to be
#      rebuilt and every OAuth client has to authorise again.
#   c) The server never creates the CouchDB database. If it is missing, the
#      server logs "database does not exist" in a restart loop. The wait below
#      checks for the database, not just for the server.
# ==============================================================================

set -euo pipefail

# ─── Helper: read a configuration value ───────────────────────────────────────
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
# Same as in the LiveSync Server add-on. Asks the Supervisor which host port,
# if any, the given container port is published on, and stops the add-on if it
# is published at all. Fails closed: if the Supervisor cannot be asked, the
# add-on does not start either. Outside a Supervisor (no SUPERVISOR_TOKEN, e.g.
# a local docker run) it only warns.
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
        log_fatal "That port speaks plain HTTP, so the bearer token and the"
        log_fatal "decrypted notes would cross the network in clear text. Clear"
        log_fatal "it under Settings -> Add-ons -> this add-on -> Network, and"
        log_fatal "connect over HTTPS instead (option ssl, port 8443, or a"
        log_fatal "tunnel add-on). See the documentation."
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
log_info "Starting the Obsidian MCP Server add-on..."

COUCHDB_URL=$(get_config_value 'couchdb_url' 'http://local-obsidian-couchdb:5984')
COUCHDB_USER=$(get_config_value 'couchdb_user' 'obsidian')
COUCHDB_PASSWORD=$(get_config_value 'couchdb_password')
COUCHDB_DATABASE=$(get_config_value 'couchdb_database' 'obsidian')
COUCHDB_PASSPHRASE=$(get_config_value 'passphrase')
COUCHDB_ID_DERIVATION_KEY=$(get_config_value 'id_derivation_key')
COUCHDB_CASE_SENSITIVE=$(get_config_value 'case_sensitive' 'false')
MCP_AUTH_TOKEN=$(get_config_value 'auth_token')
BASE_URL=$(get_config_value 'base_url')
WRITE_FOLDERS=$(get_config_value 'write_folders')
SSL=$(get_config_value 'ssl' 'false')
CERTFILE=$(get_config_value 'certfile' 'fullchain.pem')
KEYFILE=$(get_config_value 'keyfile' 'privkey.pem')
LOG_LEVEL=$(get_config_value 'log_level' 'info')

# ─── Safety checks ────────────────────────────────────────────────────────────

# Plain HTTP must never reach the LAN, whatever base_url says.
require_unpublished_port "8787/tcp"

if [[ -z "${COUCHDB_PASSWORD}" ]]; then
    log_fatal "couchdb_password is empty."
    exit 1
fi

# Without a token the MCP endpoint would be open to everyone who can reach the
# port. The server is never started that way.
if [[ -z "${MCP_AUTH_TOKEN}" ]]; then
    log_fatal "auth_token is empty."
    log_fatal "Without it the MCP endpoint is open to anyone who can reach"
    log_fatal "it, with read and write access to the whole vault."
    log_fatal "Generate one, for example: openssl rand -hex 32"
    exit 1
fi

if [[ ${#MCP_AUTH_TOKEN} -lt 32 ]]; then
    log_warn "auth_token is shorter than 32 characters."
fi

# Finding (a): an empty passphrase against an encrypted vault produces
# misleading symptoms instead of an error. Warn as clearly as possible.
if [[ -z "${COUCHDB_PASSPHRASE}" ]]; then
    log_warn "passphrase is empty. That is only correct if the LiveSync"
    log_warn "plugin runs WITHOUT end-to-end encryption. If the vault is"
    log_warn "encrypted, the server will report '0 notes' and a"
    log_warn "'ChangeManager Error watching changes' without naming the cause."
else
    log_info "End-to-end encryption is configured."
    log_warn "SECURITY NOTE: the passphrase is stored in clear text in the"
    log_warn "add-on configuration. Whoever has access to the server can read"
    log_warn "the vault. The encryption protects the transport and the"
    log_warn "database, not this host."
fi

# A trailing slash would end up doubled in every OAuth URL ("//oauth/token").
# Seen on real hardware in phase 10.
while [[ "${BASE_URL}" == */ ]]; do
    BASE_URL="${BASE_URL%/}"
done

if [[ -z "${BASE_URL}" ]]; then
    BASE_URL="http://127.0.0.1:8787"
    log_info "base_url is unset, falling back to ${BASE_URL}."
    log_info "OAuth clients such as claude.ai need a public HTTPS URL here."
elif [[ "${BASE_URL}" != https://* ]]; then
    log_warn "base_url is not HTTPS. OAuth tokens would travel in clear text."
fi

if [[ -n "${WRITE_FOLDERS}" ]]; then
    log_info "Write access is limited to: ${WRITE_FOLDERS}"
else
    log_warn "write_folders is empty: the whole vault is writable."
fi

# ─── Data directory (finding b) ───────────────────────────────────────────────
# /data belongs to root in an add-on, but the server runs as uid 1000.
DATA_DIR=/data/obsidian-mcp
mkdir -p "${DATA_DIR}"
chown -R 1000:1000 "${DATA_DIR}"
log_info "Search index and OAuth tokens: ${DATA_DIR}"

# ─── TLS certificate ──────────────────────────────────────────────────────────
# The terminator runs as uid 1000 and has to read the key, but /ssl is shared
# with other add-ons. Only the two named files are copied, outside /data (the
# key stays out of the add-on backup), and the copy is rebuilt on every start.
TLS_DIR=/run/obsidian-mcp-tls
rm -rf "${TLS_DIR}"
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
    install -d -o 1000 -g 1000 -m 0700 "${TLS_DIR}"
    install -o 1000 -g 1000 -m 0644 "/ssl/${CERTFILE}" "${TLS_DIR}/cert.pem"
    install -o 1000 -g 1000 -m 0600 "/ssl/${KEYFILE}" "${TLS_DIR}/key.pem"
    log_info "HTTPS is on: /ssl/${CERTFILE}, port 8443."
fi

# ─── Wait for CouchDB (finding c) ─────────────────────────────────────────────
log_info "Waiting for CouchDB at ${COUCHDB_URL}..."
MAX_WAIT=120
ELAPSED=0
until curl -sf -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
        "${COUCHDB_URL}/${COUCHDB_DATABASE}" > /dev/null 2>&1; do
    ELAPSED=$((ELAPSED + 3))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        log_fatal "CouchDB or the database '${COUCHDB_DATABASE}' did not"
        log_fatal "answer within ${MAX_WAIT}s at ${COUCHDB_URL}."
        log_fatal "This add-on never creates the database. Check that the"
        log_fatal "LiveSync Server add-on is running, that couchdb_url names"
        log_fatal "it (local add-ons: http://local-obsidian-couchdb:5984) and"
        log_fatal "that user, password and database name match."
        exit 1
    fi
    sleep 3
done
log_info "CouchDB and the database '${COUCHDB_DATABASE}' are reachable."

# ─── Start the server ─────────────────────────────────────────────────────────
export COUCHDB_URL COUCHDB_USER COUCHDB_PASSWORD COUCHDB_DATABASE
export COUCHDB_PASSPHRASE COUCHDB_ID_DERIVATION_KEY COUCHDB_CASE_SENSITIVE
export MCP_AUTH_TOKEN BASE_URL WRITE_FOLDERS LOG_LEVEL
export DATA_DIR
export HOME=/data

log_info "Starting the MCP server on port 8787..."

cd /app
setpriv --reuid=1000 --regid=1000 --clear-groups \
    node dist/main.js &
MCP_PID=$!
PROXY_PID=""

cleanup() {
    local exit_code=${1:-0} pid
    log_info "Stopping the add-on..."
    for pid in "${PROXY_PID:-}" "${MCP_PID:-}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    log_info "MCP server shut down cleanly."
    exit "${exit_code}"
}
trap cleanup TERM INT

# ─── Wait until ready ─────────────────────────────────────────────────────────
ELAPSED=0
until curl -sf http://127.0.0.1:8787/health > /dev/null 2>&1; do
    if ! kill -0 "${MCP_PID}" 2>/dev/null; then
        log_fatal "The MCP server exited unexpectedly. See the log above."
        exit 1
    fi
    ELAPSED=$((ELAPSED + 2))
    if [[ ${ELAPSED} -ge 60 ]]; then
        log_fatal "The MCP server did not respond within 60s."
        kill "${MCP_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

log_info "The MCP server is ready."

# ─── TLS terminator ───────────────────────────────────────────────────────────
if [[ "${SSL}" == "true" ]]; then
    TLS_CERT="${TLS_DIR}/cert.pem" TLS_KEY="${TLS_DIR}/key.pem" \
    TLS_PORT=8443 TARGET_PORT=8787 \
        setpriv --reuid=1000 --regid=1000 --clear-groups \
        node /tls-proxy.mjs &
    PROXY_PID=$!

    ELAPSED=0
    until curl -sfk https://127.0.0.1:8443/health > /dev/null 2>&1; do
        if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            log_fatal "The HTTPS listener on 8443 exited. Check that certfile"
            log_fatal "and keyfile are a matching PEM pair."
            cleanup 1
        fi
        ELAPSED=$((ELAPSED + 1))
        if [[ ${ELAPSED} -ge 30 ]]; then
            log_fatal "The HTTPS listener on 8443 did not come up within 30s."
            cleanup 1
        fi
        sleep 1
    done
    log_info "HTTPS listener is ready on port 8443."
    log_info "MCP endpoint on the LAN: https://<host-name-in-the-certificate>:8443/mcp"
    log_info "Publish 8443/tcp under Network to reach it from the LAN."
else
    log_info "HTTPS is off. Only add-ons on the internal network (for example a"
    log_info "Cloudflare Tunnel) reach the server, at http://<this-add-on>:8787."
fi
log_info "MCP endpoint for OAuth clients: ${BASE_URL}/mcp"

# ─── Supervise the processes ──────────────────────────────────────────────────
# Whichever of server and TLS terminator ends first ends the add-on.
set +e
if [[ -n "${PROXY_PID}" ]]; then
    wait -n "${MCP_PID}" "${PROXY_PID}"
else
    wait "${MCP_PID}"
fi
EXIT_CODE=$?
set -e

if [[ ${EXIT_CODE} -ne 0 ]]; then
    log_fatal "A process of the add-on exited unexpectedly (exit code: ${EXIT_CODE})."
fi
cleanup "${EXIT_CODE}"
