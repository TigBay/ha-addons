# Changelog

All notable changes to this add-on are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
