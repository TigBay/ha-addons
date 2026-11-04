#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# Obsidian MCP Server – start script
#
# Flow:
#   1. Read the configuration from /data/options.json
#   2. Refuse to start on an unsafe configuration (no token, no passphrase)
#   3. Hand /data to uid 1000 and point DATA_DIR at it
#   4. Wait until CouchDB answers and the database exists
#   5. Start the server as uid 1000, supervise it, stop cleanly on SIGTERM
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
LOG_LEVEL=$(get_config_value 'log_level' 'info')

# ─── Safety checks ────────────────────────────────────────────────────────────

if [[ -z "${COUCHDB_PASSWORD}" ]]; then
    log_fatal "couchdb_password is empty."
    exit 1
fi

# Without a token the MCP endpoint would be open to everyone who can reach the
# port. The server is never started that way.
if [[ -z "${MCP_AUTH_TOKEN}" ]]; then
    log_fatal "auth_token is empty."
    log_fatal "Without it the MCP endpoint is open to anyone who can reach"
    log_fatal "port 8787, with read and write access to the whole vault."
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

cleanup() {
    local exit_code=${1:-0}
    log_info "Stopping the add-on..."
    if [[ -n "${MCP_PID:-}" ]] && kill -0 "${MCP_PID}" 2>/dev/null; then
        kill -TERM "${MCP_PID}" 2>/dev/null || true
        wait "${MCP_PID}" 2>/dev/null || true
    fi
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
log_info "MCP endpoint: ${BASE_URL}/mcp"
log_warn "Never expose port 8787 to the internet without HTTPS. Use a"
log_warn "Cloudflare Tunnel, Tailscale or a reverse proxy with a certificate."

# ─── Supervise the main process ───────────────────────────────────────────────
set +e
wait "${MCP_PID}"
EXIT_CODE=$?
set -e

if [[ ${EXIT_CODE} -ne 0 ]]; then
    log_fatal "The MCP server exited unexpectedly (exit code: ${EXIT_CODE})."
fi
cleanup "${EXIT_CODE}"
