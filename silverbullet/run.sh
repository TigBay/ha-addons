#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# SilverBullet Home Assistant Add-on – start script
#
# Flow:
#   1. Read the configuration from /data/options.json
#   2. Create the space directory and check that it is writable
#   3. Generate an internal auth token (never logged)
#   4. Start SilverBullet and wait until it is ready (.instance)
#   5. Optional: start the MCP bridge (when enable_mcp: true)
#   6. Supervise the processes, stop cleanly on SIGTERM
# ==============================================================================

set -euo pipefail

# ─── Helper: read configuration from options.json ────────────────────
# bashio reads the options through the Supervisor API. Without a Supervisor
# (local Docker tests) that fails, so /data/options.json is read directly with
# jq. Under Home Assistant the file exists as well, so the fallback is harmless.
get_config_value() {
    local key="$1"
    local default="${2:-}"
    local value=""

    # Try bashio first (works in Home Assistant or when the Supervisor API is reachable)
    value=$(bashio::config "$key" 2>/dev/null) || value=""

    # If the Supervisor API is unavailable or the value is null/empty, read the file directly
    if [[ -z "$value" || "$value" == "null" ]] && [[ -f /data/options.json ]]; then
        value=$(jq -r ".${key} // empty" /data/options.json 2>/dev/null || true)
    fi

    if [[ -z "$value" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# ─── Read configuration ─────────────────────────────────────────────────────
bashio::log.info "Starting the SilverBullet add-on..."

SB_USER=$(get_config_value 'sb_user')
SPACE_PATH=$(get_config_value 'space_path')
ADDITIONAL_ARGS=$(get_config_value 'additional_args' '')

ENABLE_MCP=$(get_config_value 'enable_mcp' 'false')
if [[ "$ENABLE_MCP" != "true" && "$ENABLE_MCP" != "false" ]]; then
    ENABLE_MCP="false"
fi

MCP_TOKEN_CONFIG=$(get_config_value 'mcp_token' '')

# ─── Security checks ──────────────────────────────────────────────────────────

# SB_USER must have the format "username:password"
if [[ -z "${SB_USER:-}" ]] || [[ "${SB_USER}" != *":"* ]]; then
    bashio::log.fatal "sb_user must have the format 'username:password'."
    bashio::log.fatal "Example: admin:my-secure-password"
    exit 1
fi

USER_PART="${SB_USER%%:*}"
PASS_PART="${SB_USER#*:}"

if [[ -z "${USER_PART}" ]]; then
    bashio::log.fatal "The username in sb_user must not be empty."
    exit 1
fi

if [[ -z "${PASS_PART}" ]]; then
    bashio::log.fatal "The password in sb_user must not be empty."
    bashio::log.fatal "SilverBullet is never started without authentication."
    exit 1
fi

# SPACE_PATH must be set and not empty
if [[ -z "${SPACE_PATH:-}" ]]; then
    bashio::log.fatal "space_path must not be empty."
    exit 1
fi

if [[ "${PASS_PART}" == "changeme" ]]; then
    bashio::log.warning "Security warning: you are using the default password 'changeme'."
    bashio::log.warning "Change it in the add-on configuration (option sb_user)."
fi

bashio::log.info "Username: ${USER_PART}"
bashio::log.info "Space directory: ${SPACE_PATH}"

# ─── Prepare the space directory ──────────────────────────────────────────────
if ! mkdir -p "${SPACE_PATH}" 2>/dev/null; then
    bashio::log.fatal "Could not create the space directory: ${SPACE_PATH}"
    bashio::log.fatal "Make sure /share is mounted in the add-on."
    exit 1
fi

if [[ ! -w "${SPACE_PATH}" ]]; then
    bashio::log.fatal "The space directory is not writable: ${SPACE_PATH}"
    exit 1
fi

bashio::log.info "The space directory is ready and writable."

# ─── Prepare the add-on data path ────────────────────────────────────────────
mkdir -p /data/silverbullet

# ─── Generate the internal auth token ─────────────────────────────────────────
# The MCP bridge uses this token to talk to SilverBullet.
# It is NEVER written to the log.
SB_AUTH_TOKEN="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 || true)"
if [[ -z "${SB_AUTH_TOKEN}" ]]; then
    # Fallback if /dev/urandom is not available
    SB_AUTH_TOKEN="$(cat /proc/sys/kernel/random/uuid | tr -d '-')$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
fi

# Store the token safely in a file (for the MCP bridge and local tests)
printf '%s\n' "${SB_AUTH_TOKEN}" > /data/sb_auth_token.txt
chmod 600 /data/sb_auth_token.txt

export SB_AUTH_TOKEN

# ─── Set SilverBullet environment variables ────────────────────────────────────
export SB_USER
export SB_FOLDER="${SPACE_PATH}"

# Chromium for the Runtime API (plugs / AI tools)
if [[ -x /usr/bin/chromium-browser ]]; then
    export SB_CHROME_PATH="/usr/bin/chromium-browser"
elif [[ -x /usr/bin/chromium ]]; then
    export SB_CHROME_PATH="/usr/bin/chromium"
fi
export SB_CHROME_DATA_DIR="/tmp/sb-chrome"
mkdir -p /tmp/sb-chrome

# ─── Start SilverBullet ───────────────────────────────────────────────────────
bashio::log.info "Starting SilverBullet on port 3000..."

SB_ARGS=()
# Single-space mode: in this mode SB_USER and SB_AUTH_TOKEN are used as
# environment variables for basic auth and bearer auth (Runtime API).
# Without --single SilverBullet would start in multi-space mode, where
# authentication is configured differently.
SB_ARGS+=("--single")
# Host and port can also be set through environment variables (SB_HOSTNAME,
# SB_PORT), but they are passed explicitly as arguments to keep the setup clear.
SB_ARGS+=("--hostname" "0.0.0.0")
SB_ARGS+=("--port" "3000")
if [[ -n "${ADDITIONAL_ARGS}" ]]; then
    read -ra EXTRA_ARGS <<< "${ADDITIONAL_ARGS}"
    SB_ARGS+=("${EXTRA_ARGS[@]}")
fi

# Start SilverBullet in the background
/usr/local/bin/silverbullet "${SPACE_PATH}" "${SB_ARGS[@]}" &
SB_PID=$!

# ─── Signal handler and MCP PID ───────────────────────────────────────────────
MCP_PID=""

cleanup() {
    local exit_code=${1:-0}
    bashio::log.info "Stopping the add-on..."

    # Stop the MCP bridge first
    if [[ -n "${MCP_PID}" ]] && kill -0 "${MCP_PID}" 2>/dev/null; then
        bashio::log.info "Stopping the MCP bridge (PID: ${MCP_PID})..."
        kill -TERM "${MCP_PID}" 2>/dev/null || true
        wait "${MCP_PID}" 2>/dev/null || true
        bashio::log.info "MCP bridge stopped."
    fi

    # Stop SilverBullet
    if [[ -n "${SB_PID}" ]] && kill -0 "${SB_PID}" 2>/dev/null; then
        bashio::log.info "Stopping SilverBullet (PID: ${SB_PID})..."
        kill -TERM "${SB_PID}" 2>/dev/null || true
        wait "${SB_PID}" 2>/dev/null || true
        bashio::log.info "SilverBullet stopped."
    fi

    bashio::log.info "SilverBullet add-on shut down cleanly."
    exit "${exit_code}"
}

trap cleanup TERM INT

bashio::log.info "SilverBullet started (PID: ${SB_PID})."

# ─── Wait until ready ─────────────────────────────────────────────────────────
bashio::log.info "Waiting for SilverBullet..."
MAX_WAIT=60
ELAPSED=0

until curl -sf http://127.0.0.1:3000/.instance > /dev/null 2>&1; do
    # Check that SilverBullet is still running
    if ! kill -0 "${SB_PID}" 2>/dev/null; then
        bashio::log.fatal "SilverBullet exited unexpectedly."
        exit 1
    fi

    ELAPSED=$((ELAPSED + 2))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        bashio::log.fatal "SilverBullet did not respond within ${MAX_WAIT}s."
        kill "${SB_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

bashio::log.info "SilverBullet is ready and reachable."
bashio::log.info "Web interface: http://<home-assistant-ip>:3000"

# ─── Optionally start the MCP bridge ─────────────────────────────────────────
if [[ "${ENABLE_MCP}" == "true" ]]; then
    bashio::log.info "Enabling the MCP bridge (port: 3033)..."

    # Process the MCP token
    MCP_TOKEN="${MCP_TOKEN_CONFIG}"

    if [[ -z "${MCP_TOKEN}" ]]; then
        # Generate a strong token automatically (64 characters)
        MCP_TOKEN="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 || true)"
        if [[ -z "${MCP_TOKEN}" ]]; then
            MCP_TOKEN="$(cat /proc/sys/kernel/random/uuid | tr -d '-')$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
        fi

        # Store the token safely in a file (permissions 600)
        printf '%s\n' "${MCP_TOKEN}" > /data/mcp_token.txt
        chmod 600 /data/mcp_token.txt

        bashio::log.warning "No mcp_token configured – a token was generated automatically."
        bashio::log.info "Token stored in: /data/mcp_token.txt (it is not written to the log)."
    fi

    # Set environment variables for the MCP bridge
    export SB_URL="http://127.0.0.1:3000"
    export MCP_PORT=3033
    export MCP_TOKEN

    if ! command -v silverbullet-ai-mcp > /dev/null 2>&1; then
        bashio::log.error "silverbullet-ai-mcp binary not found – the MCP bridge cannot be started."
    else
        silverbullet-ai-mcp &
        MCP_PID=$!

        # The bridge exits when the 'silverbullet-ai' plug is missing in the space.
        # That only happens after Chromium has loaded the space (this can take more
        # than 10 s). So wait up to 60 s until port 3033 answers or the bridge has
        # exited. SilverBullet itself keeps running in any case.
        for _ in $(seq 1 60); do
            kill -0 "${MCP_PID}" 2>/dev/null || break
            curl -s -o /dev/null -m 2 http://127.0.0.1:3033/ 2>/dev/null && break
            sleep 1
        done

        if kill -0 "${MCP_PID}" 2>/dev/null; then
            bashio::log.info "MCP bridge started (PID: ${MCP_PID})."
            bashio::log.info "MCP endpoint: http://<host-ip>:3033/mcp"
            bashio::log.warning "SECURITY NOTE: never expose the MCP endpoint publicly without a token!"
            bashio::log.warning "Use it only on the local network or through a secured VPN/Tailscale."
        else
            wait "${MCP_PID}" 2>/dev/null || true
            bashio::log.error "MCP bridge exited. Is the plug 'silverbullet-ai' installed in the space? See DOCS.md."
            MCP_PID=""
        fi
    fi
else
    bashio::log.info "The MCP bridge is disabled (enable_mcp: false)."
fi

# ─── Supervise the main process ──────────────────────────────────────────────
# The script blocks here until SilverBullet exits or SIGTERM arrives.
set +e
wait "${SB_PID}"
EXIT_CODE=$?
set -e

if [[ ${EXIT_CODE} -ne 0 ]]; then
    bashio::log.error "SilverBullet exited unexpectedly (exit code: ${EXIT_CODE})."
    bashio::log.error "Check the logs for the cause."
fi

cleanup "${EXIT_CODE}"
