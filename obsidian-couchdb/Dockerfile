# =============================================================================
# Obsidian LiveSync Server (CouchDB) – Home Assistant add-on
#
# There is no single binary to copy into an Alpine base image: CouchDB ships a
# complete Erlang/OTP runtime. The official CouchDB
# image is therefore the base, and the Home Assistant conventions (bashio,
# run.sh, labels) are layered on top.
#
# Consequence: BUILD_FROM is unused and bashio has to be installed. That is the
# price for keeping the Debian packages and the Erlang version matched to the
# CouchDB release.
# =============================================================================

FROM couchdb:3.5.3

LABEL \
    org.opencontainers.image.title="Obsidian LiveSync Server" \
    org.opencontainers.image.description="CouchDB sync backend for Obsidian Self-hosted LiveSync" \
    org.opencontainers.image.source="https://github.com/TigBay/ha-addons" \
    org.opencontainers.image.licenses="MIT" \
    io.hass.name="Obsidian LiveSync Server" \
    io.hass.description="CouchDB sync backend for Obsidian Self-hosted LiveSync" \
    io.hass.type="addon"

# Only jq is missing (bashio needs it). curl, tar, bash, setpriv, tini and the
# CA certificates are already present — checked against the image in the PoC.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
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
RUN chmod a+x /run.sh

# No credentials in the health check. That works because run.sh sets
# require_valid_user_except_for_up.
HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=60s \
    --retries=3 \
    CMD curl -sf http://127.0.0.1:5984/_up || exit 1

# The image's own entrypoint (tini) is bypassed: run.sh handles configuration
# and permissions and starts CouchDB itself.
ENTRYPOINT []
CMD ["/run.sh"]
