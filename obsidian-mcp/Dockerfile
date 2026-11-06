# =============================================================================
# Obsidian MCP Server – Home Assistant add-on
#
# Same reasoning as the CouchDB add-on: the upstream image is the base, and the
# Home Assistant conventions are layered on top. Building the server from
# source would mean maintaining a Node toolchain and the vendored
# livesync-commonlib, and the PoC showed that the exact bundled version matters
# for chunk compatibility with the LiveSync plugin.
# =============================================================================

FROM ghcr.io/es617/obsidian-sync-mcp:v0.10.0

# Build steps need root, and the add-on also starts as root: run.sh has to fix
# the ownership of /data (root-owned in an add-on) before the server can use it.
# It then drops to uid 1000 with setpriv, so the node process itself never runs
# as root. Verified: "node dist/main.js -> uid 1000".
# hadolint ignore=DL3002,DL3066
USER root

LABEL \
    org.opencontainers.image.title="Obsidian MCP Server" \
    org.opencontainers.image.description="MCP server for an end-to-end encrypted Obsidian LiveSync vault" \
    org.opencontainers.image.source="https://github.com/TigBay/ha-addons" \
    org.opencontainers.image.licenses="MIT" \
    io.hass.name="Obsidian MCP Server" \
    io.hass.description="MCP server for an end-to-end encrypted Obsidian LiveSync vault" \
    io.hass.type="addon"

# The image is Debian bookworm based but ships neither curl nor jq.
# curl: health check and the readiness wait. jq: required by bashio.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

# bashio for bashio::log and bashio::config. Version pinned.
ARG BASHIO_VERSION=0.16.2
RUN curl -fsSL "https://github.com/hassio-addons/bashio/archive/refs/tags/v${BASHIO_VERSION}.tar.gz" \
        -o /tmp/bashio.tar.gz \
    && mkdir -p /tmp/bashio \
    && tar -xzf /tmp/bashio.tar.gz -C /tmp/bashio --strip-components=1 \
    && mv /tmp/bashio/lib /usr/lib/bashio \
    && ln -s /usr/lib/bashio/bashio /usr/bin/bashio \
    && rm -rf /tmp/bashio /tmp/bashio.tar.gz

COPY run.sh /run.sh
COPY tls-proxy.mjs /tls-proxy.mjs
RUN chmod a+x /run.sh && chmod a+r /tls-proxy.mjs

# /health answers without a token; /mcp would answer 400 or 401.
HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=30s \
    --retries=3 \
    CMD curl -sf http://127.0.0.1:8787/health || exit 1

# run.sh starts as root to fix up the permissions of /data and then drops to
# uid 1000. The image's own entrypoint is bypassed.
ENTRYPOINT []
CMD ["/run.sh"]
