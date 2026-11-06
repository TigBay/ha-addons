# Changelog

All notable changes to this add-on are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-06

### Security

- Plain HTTP is no longer offered to the network. The server speaks only
  plain HTTP, so on the published port 8787 the bearer token and the decrypted
  notes crossed the LAN in clear text. Port 8787 is no longer published by
  default, and the add-on now refuses to start if 8787 has a host port — also
  one kept from an earlier version, and whatever `base_url` says. The check
  asks the Supervisor at every start and fails closed if it cannot.

### Added

- Options `ssl`, `certfile` and `keyfile`: an HTTPS listener on port 8443,
  served by `tls-proxy.mjs`, a small TLS terminator built on Node's standard
  library that forwards each request unchanged to the server and streams the
  answers (server-sent events included). The key is copied into the container
  with mode 0600, outside `/data`, so it is not part of the add-on backup.
- `hassio_api: true` for the port check, and a read-only `/ssl` mount.

### Changed

- **Breaking:** clients can no longer connect to `http://<ha-ip>:8787/mcp`.
  Turn on `ssl` and publish 8443, or reach the add-on through a tunnel or
  proxy add-on on the internal network. An installation that kept a host port
  for 8787 stops with a message naming the port until it is cleared under
  *Network*.

### Notes

- HTTPS and the port check were tested in local Docker and against a simulated
  Supervisor, not yet on Home Assistant hardware.

## [0.1.1] - 2026-11-05

### Fixed

- A trailing slash in `base_url` is removed at startup. Before, a value such
  as `https://api.example.org/` produced doubled slashes in the endpoint log
  line, in all OAuth endpoints, in the issuer and in the `resource_metadata`
  link of the `WWW-Authenticate` header. Found on real hardware behind a
  Cloudflare Tunnel.

## [0.1.0] - 2026-11-04

First draft, built and tested in local Docker only — not yet on Home Assistant
hardware.

### Added

- obsidian-sync-mcp v0.10.0 as an MCP server for an end-to-end encrypted
  Obsidian LiveSync vault.
- Configuration options for the CouchDB connection, the encryption passphrase,
  the bearer token, the public base URL and a write-access limit.
- `DATA_DIR=/data/obsidian-mcp`, so the search index and the issued OAuth
  tokens survive an add-on update and are part of the add-on backup. The
  variable is undocumented upstream and was read out of the bundled code.
- A refusal to start without `auth_token`, and an explicit warning when the
  encryption passphrase is empty.
- A wait for CouchDB **and** the database before the server starts, with an
  error message naming the likely cause. The server never creates the database
  itself.
- `/health` as the watchdog endpoint; it answers without a token, unlike
  `/mcp`.
- The server process runs as uid 1000, not as root.
- Clean shutdown on SIGTERM (measured: 1 s, exit code 0).

### Notes

- AppArmor is off until a profile has been tested on real hardware.
- No published image yet; the Supervisor builds the add-on locally.
