# Changelog

All notable changes to this add-on are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.1] - 2026-11-08

### Fixed

- Removed the *Open Web UI* button. The Supervisor showed it even when 6984
  had no host port and then linked to port `None`. Fauxton is at
  `https://<host>:6984/_utils/` once `ssl` is on and 6984 is published.

### Notes

- The port check and the watchdog are verified on Home Assistant OS (Dell
  Wyse): a published 5984 stops the add-on with the message naming the port,
  and the watchdog probes the unpublished 5984 without false restarts.

## [0.2.0] - 2026-11-06

### Security

- Plain HTTP is no longer offered to the network. CouchDB authenticates with
  HTTP Basic, so every request on 5984 carried the administrator password in
  clear text to anyone watching the LAN. Port 5984 is no longer published by
  default, and the add-on now refuses to start if 5984 has a host port — also
  one kept from an earlier version. The check asks the Supervisor at every
  start and fails closed if it cannot.

### Added

- Options `ssl`, `certfile` and `keyfile`: an HTTPS listener on port 6984 with
  a certificate from `/ssl`. The add-on stops if the files are missing or the
  listener does not come up. The key is copied into the container with mode
  0600, outside `/data`, so it is not part of the add-on backup.
- `hassio_api: true` for the port check, and a read-only `/ssl` mount.

### Changed

- **Breaking:** Obsidian can no longer connect to `http://<ha-ip>:5984`. Turn
  on `ssl` and publish 6984, or put a TLS proxy add-on in front of
  `http://local-obsidian-couchdb:5984`. An installation that kept a host port
  for 5984 stops with a message naming the port until it is cleared under
  *Network*. The MCP add-on is not affected; it uses the internal network.
- The *Open Web UI* link now points to HTTPS on 6984 and only appears when
  that port is published.

### Notes

- HTTPS and the port check were tested in local Docker and against a simulated
  Supervisor, not yet on Home Assistant hardware.

## [0.1.1] - 2026-11-05

### Added

- Option `cors_headers`: extra request header names for the CORS preflight.
  Without it CouchDB answers a preflight that asks for a header such as
  `cf-access-client-id` with 401. Names are validated before they reach the
  configuration file.

### Notes

- Verified on a Dell Wyse (Home Assistant OS 18.4): installs from
  `/local_apps`, survives stop/start, rebuild, restore from a backup and a host
  reboot.

## [0.1.0] - 2026-11-04

First draft, built and tested in local Docker only — not yet on Home Assistant
hardware.

### Added

- CouchDB 3.5.3 as a sync backend for Obsidian Self-hosted LiveSync.
- Configuration options for administrator, database, CORS origins and log level.
- The database under `/data/couchdb`, so it is part of the add-on backup.
- `require_valid_user_except_for_up`, so the watchdog and the health check work
  while every other path still requires authentication.
- A check after every start that the database is not reachable without
  credentials; the add-on stops itself if it is.
- Clean shutdown on SIGTERM (measured: 1 s, exit code 0).

### Notes

- AppArmor is off until a profile has been tested on real hardware.
- No published image yet; the Supervisor builds the add-on locally.
