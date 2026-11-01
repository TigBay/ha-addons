# =============================================================================
# SilverBullet Home Assistant Add-on
# Dockerfile – multi-stage build
#
# Stage 1: extract the SilverBullet binary from the official image (Alpine/musl compatible)
# Stage 2: Home Assistant compatible Alpine base image with Chromium and the MCP bridge
# =============================================================================

# Multi-arch base image (amd64 + aarch64). The Supervisor only passes BUILD_FROM
# when a (deprecated) build.yaml exists, so the default value lives here.
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.23

# Stage 1: extract the static SilverBullet binary from the official image
FROM ghcr.io/silverbulletmd/silverbullet:2.12.1 AS silverbullet-source

# =============================================================================
# Stage 2: production image (Home Assistant compatible, Alpine based)
# =============================================================================
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# Metadata labels (OCI standard). The Supervisor sets io.hass.version and
# io.hass.arch itself for local builds; CI sets them through docker/metadata-action.
LABEL \
    org.opencontainers.image.title="SilverBullet HA Add-on" \
    org.opencontainers.image.description="Self-hosted Markdown note-taking system for Home Assistant" \
    org.opencontainers.image.source="https://github.com/TigBay/ha-addons" \
    org.opencontainers.image.licenses="MIT" \
    io.hass.name="SilverBullet" \
    io.hass.description="Self-hosted Markdown note-taking system" \
    io.hass.type="app"

# Copy the static SilverBullet binary from stage 1
COPY --from=silverbullet-source /silverbullet /usr/local/bin/silverbullet

# Install system dependencies:
# - chromium: for the SilverBullet Runtime API (required for AI/MCP plugs)
# - nodejs, npm: Node.js >= 20 for silverbullet-ai-mcp
# - git, curl, ca-certificates: helper tools
# jq is already included in the base image
# hadolint ignore=DL3018,DL3016
RUN apk add --no-cache \
        ca-certificates \
        chromium \
        curl \
        git \
        nodejs \
        npm \
    && npm install --global --no-fund --no-audit silverbullet-ai-mcp@0.9.3 \
    && npm cache clean --force \
    && chmod a+x /usr/local/bin/silverbullet

# Copy the start script and make it executable
COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Health check through SilverBullet's official .instance endpoint
# hadolint ignore=DL3025
HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=30s \
    --retries=3 \
    CMD curl -sf http://localhost:3000/.instance || exit 1

# Start command
CMD ["/run.sh"]
