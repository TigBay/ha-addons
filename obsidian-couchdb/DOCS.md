# Obsidian LiveSync Server add-on – documentation

## Overview

This add-on runs **CouchDB 3.5.3** as the sync backend for the Obsidian plugin
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync). Your notes
stay on your own hardware, and with end-to-end encryption enabled the server
stores only ciphertext — it never sees the plain text of a note, not even in
the database.

Together with the **Obsidian MCP Server** add-on it replaces Obsidian Sync and
makes the vault reachable from an AI assistant.

> **Unofficial:** a community add-on, not affiliated with the CouchDB project,
> the Apache Software Foundation or Self-hosted LiveSync.

## Getting started

### 1. Configuration

| Option | Default | Description |
|---|---|---|
| `admin_user` | `obsidian` | CouchDB administrator |
| `admin_password` | *(empty)* | **Required.** The add-on refuses to start without it |
| `database` | `obsidian` | Database name; must match the LiveSync setting |
| `cors_origins` | `app://obsidian.md,capacitor://localhost,http://localhost` | Origins Obsidian connects from. Desktop, mobile, local |
| `log_level` | `warning` | CouchDB log level |

There is no default password on purpose. CouchDB without an administrator runs
in *admin party* mode, where everyone on the network may read and write.

### 2. Start the add-on

Click **Start**. The first start takes a little longer because CouchDB creates
its system databases. The log ends with:

```
[INFO]  Mandatory login is in effect (without credentials: HTTP 401).
```

That line is a check, not a formality: the add-on verifies after every start
that the database really is not reachable without credentials, and stops itself
if it is.

### 3. Set up Obsidian

In Obsidian: **Settings → Self-hosted LiveSync → Setup wizard**.

| Field | Value |
|---|---|
| URI | `http://<your-ha-ip>:5984` |
| Username | your `admin_user` |
| Password | your `admin_password` |
| Database name | your `database` |

Then enable end-to-end encryption, set a passphrase and choose
**Initialise or overwrite the remote** on the first device. On every further
device use the setup URI or **Join this device** — never *initialise* again, it
overwrites the server.

> **The passphrase is not stored anywhere on the server.** If you lose it, the
> notes in the database cannot be recovered. Keep it in a password manager.

### 4. Phone

Obsidian Mobile connects **only over HTTPS**; the app says so in the setup
dialog. Port 5984 over plain HTTP works on the desktop but not on the phone.
Your options:

- **Tailscale** — the Home Assistant Tailscale add-on can advertise other local
  services inside your tailnet (`services` option, Serve mode). Good for your
  own devices.
- **Cloudflare Tunnel** or a reverse proxy with a Let's Encrypt certificate —
  needed if the endpoint has to be reachable without a VPN client.

## Backup

The database lives under `/data/couchdb` and is therefore part of the normal
Home Assistant add-on backup. Nothing else needs to be saved — except the
encryption passphrase, which is not in the backup.

A backup taken while the add-on is running can catch CouchDB mid-write. For a
consistent copy, stop the add-on first.

## Known limitations

- **AppArmor is off.** CouchDB brings a complete Erlang runtime; an untested
  profile breaks the add-on in ways that are hard to diagnose. A profile will
  follow once it has been tested on real hardware.
- **`/_utils/` (Fauxton) asks for credentials**, including through the
  Home Assistant panel. That is intended: mandatory login applies to every path
  except `/_up`.
- **No multi-node setup.** The add-on configures a single node
  (`single_node = true`). That is the right shape for a home server and the
  only one LiveSync needs.
- **Only built locally so far.** The add-on has no published image; the
  Supervisor builds it from the Dockerfile on installation.

## Why some things look the way they do

Four properties of the official CouchDB image shaped this add-on. All four were
found the hard way in a proof of concept.

**Configuration is rewritten on every start.** Settings applied through
CouchDB's REST API land in the container's write layer, not under `/data`. An
add-on update rebuilds the container and discards them — including
`require_valid_user`, which would leave the database open. `run.sh` therefore
writes `/opt/couchdb/etc/local.d/10-addon.ini` on every start. Editing that
file by hand has no effect.

**`/_up` stays open without credentials.** Once `require_valid_user` applies,
CouchDB answers `401` on every path, `/_up` included — and the Home Assistant
watchdog cannot send credentials. `require_valid_user_except_for_up = true`
exempts exactly that one path. Verified: `/_up` → 200, `/` and
`/<database>` → 401.

**The configuration file must be writable.** CouchDB replaces the clear-text
password in `[admins]` with a PBKDF2 hash and writes the file back while doing
so. On a read-only file the image's entrypoint fails on a `chmod` — silently,
because of `set -e` combined with `chmod -f`. The container then exits with
code 1 and an empty log.

**CORS belongs in two sections.** In CouchDB 3 both `[httpd] enable_cors` and
`[chttpd] enable_cors` have to be set. With only one of them, Obsidian fails
with a CORS error that does not name the cause.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Add-on stops with "admin_password is empty" | Set a password in the configuration |
| Add-on stops with "The database is reachable without credentials" | The configuration did not take effect. Check the log above that line |
| Obsidian reports a CORS error | `cors_origins` does not contain the origin the client uses |
| Obsidian Mobile will not connect | HTTP is not enough; see "Phone" |
| `0 notes` in the MCP add-on | The passphrase there does not match the one in Obsidian |
