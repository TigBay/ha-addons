# Changelog

All notable changes to this add-on are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
