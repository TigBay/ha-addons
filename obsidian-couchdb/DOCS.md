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
| `cors_headers` | *(empty)* | Extra request header names the client may send, comma-separated (for example `cf-access-client-id, cf-access-client-secret`). Only needed when a proxy in front checks a token |
| `ssl` | `false` | Serve HTTPS on port 6984. Needed for Obsidian to connect directly |
| `certfile` | `fullchain.pem` | Certificate (PEM, full chain) under `/ssl` |
| `keyfile` | `privkey.pem` | Private key (PEM) under `/ssl` |
| `log_level` | `warning` | CouchDB log level |

There is no default password on purpose. CouchDB without an administrator runs
in *admin party* mode, where everyone on the network may read and write.

### Network access and encryption

CouchDB authenticates with HTTP Basic: every request carries the administrator
password, only Base64-encoded. Over plain HTTP anyone who can watch the network
reads it. The add-on therefore never offers plain HTTP outside the host:

| Port | Protocol | Who uses it |
|---|---|---|
| 5984 | plain HTTP | Other add-ons only, over the internal network (`http://local-obsidian-couchdb:5984`). **Never published.** The add-on refuses to start if 5984 has a host port under *Network* |
| 6984 | HTTPS | Obsidian and Fauxton. Off unless `ssl` is on and 6984 has a host port |

To connect Obsidian directly:

1. Put a certificate and its key into `/ssl`, for example with the Let's
   Encrypt or DuckDNS add-on. The certificate must be valid for the host name
   your devices use — Obsidian, and the phone app in particular, reject
   self-signed certificates.
2. Make that host name resolve to the Home Assistant machine in your network.
3. Set `ssl: true` (and `certfile`/`keyfile` if your files have other names).
4. Under *Network*, enter a host port for **6984/tcp**. Leave 5984/tcp empty.

The alternative is a TLS proxy or tunnel add-on (NGINX Proxy Manager,
Cloudflare Tunnel, Tailscale) that reaches `http://local-obsidian-couchdb:5984`
over the internal network and offers HTTPS to the outside. Then `ssl` can stay
off and no port of this add-on is published.

The add-on asks the Supervisor at every start whether 5984 is published, and
does not start if the answer is yes — or if the Supervisor cannot be asked.

### 2. Start the add-on

Click **Start**. The first start takes a little longer because CouchDB creates
its system databases. The log ends with:

```
[INFO]  Mandatory login is in effect (without credentials: HTTP 401).
```

That line is a check, not a formality: the add-on verifies after every start
that the database really is not reachable without credentials, and stops itself
if it is.

**Turn the watchdog on.** On the add-on's *Info* page, switch **Watchdog** on.
It is off after installation, even though this add-on defines a watchdog URL:
the URL only says what to check, the switch decides whether the Supervisor
acts on it. Verified on a Dell Wyse: with the switch on, a failing `/_up` made
the Supervisor log "Watchdog found app … is unhealthy, restarting..." and the
add-on was back after about 80 seconds.

### 3. Set up Obsidian

In Obsidian: **Settings → Self-hosted LiveSync → Setup wizard**.

| Field | Value |
|---|---|
| URI | `https://<host-name-in-the-certificate>:<host-port-of-6984>`, or the HTTPS URL of your proxy |
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

Obsidian Mobile connects **only over HTTPS**, with a certificate it trusts. In
your home network the `ssl` setup above works for the phone too. Away from
home:

- **Tailscale** — the Home Assistant Tailscale add-on can advertise other local
  services inside your tailnet (`services` option, Serve mode). Good for your
  own devices.
- **Cloudflare Tunnel** or a reverse proxy with a Let's Encrypt certificate —
  needed if the endpoint has to be reachable without a VPN client. Point it at
  `http://local-obsidian-couchdb:5984`, not at a published port.

## Backup

The database lives under `/data/couchdb` and is therefore part of the normal
Home Assistant add-on backup. Nothing else needs to be saved — except the
encryption passphrase, which is not in the backup.

A backup taken while the add-on is running can catch CouchDB mid-write. For a
consistent copy, stop the add-on first.

A Home Assistant backup also contains the add-on options, so the administrator
password is in it in clear text unless the backup itself is password-protected.
Protect backups that leave the machine.

Restoring a partial backup of just this add-on and the MCP add-on was tested:
after deleting the database on purpose, the restore brought back every
document, the encryption salt, the mandatory login and the CORS settings.

### Moving an existing database here

Do not rely on `_replicate` alone. CouchDB replication skips `_local`
documents, and LiveSync keeps the PBKDF2 salt of the end-to-end encryption in
`_local/obsidian_livesync_sync_parameters` (next to
`_local/obsydian_livesync_milestone`). Without the salt every note arrives and
none can be decrypted, although the document counts match. Copy both documents
by hand (`GET` on the source, `PUT` on the target without `_rev`), or let
Obsidian upload the vault fresh with "Initialise or overwrite the remote".

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
  Supervisor builds it from the Dockerfile on installation. On a Dell Wyse
  (Celeron J4105) that took 56 seconds; a rebuild with a warm cache took 17.
- **File names are not encrypted.** Path obfuscation is off by default, so
  file names appear in clear text in the database and in backups. Note
  contents are encrypted.
- **Extra headers need a CORS entry.** A request header the plugin adds
  itself (for example a proxy token under "Custom Headers") is rejected by the
  CORS preflight with `401` unless CouchDB lists it in `[cors] headers`. Put the
  names in the `cors_headers` option. Verified by hand: without the entry the
  preflight answered `401`, with it `204`.
- **The HTTPS listener and the port check are not yet verified on Home
  Assistant hardware.** Both were tested in local Docker: HTTPS on 6984
  answered `/_up` with 200 and the database with 401 without credentials and
  200 with them; the port check refused a published 5984 against a simulated
  Supervisor. Not yet checked on a real Supervisor: the watchdog with 5984
  unpublished (expected to work, because the Supervisor probes the container
  port) and the *Open Web UI* button, which only appears when 6984 is
  published.
- **Plain HTTP stays inside the host.** Other add-ons still talk to 5984 over
  the internal Docker network in clear text. Reading that traffic needs a
  compromised add-on on the same machine, not just a seat on the LAN.

## Resource use

Measured on a Dell Wyse (Celeron J4105, 4 GB RAM, other add-ons running), with
528 notes: about 80–95 MB RAM and about 1 % CPU when idle. The measurement
script and raw values are in the project's `REPORT.md`.

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
| Add-on stops with "5984/tcp is published on host port …" | Clear the 5984/tcp field under *Network*; connect over 6984 instead. Typical after updating from 0.1.x |
| Add-on stops with "Could not ask the Supervisor" | The Supervisor API did not answer. Restart the add-on; if it persists, check the Supervisor log |
| Add-on stops with "/ssl/… does not exist" | `ssl` is on but the certificate or key is missing under `/ssl` |
| Add-on stops with "The HTTPS listener on 6984 did not come up" | Certificate and key do not match, or are not PEM |
| Obsidian cannot connect after the update | 0.2.0 no longer serves plain HTTP to the LAN. See "Network access and encryption" |
| Obsidian reports a CORS error | `cors_origins` does not contain the origin the client uses |
| Obsidian Mobile will not connect | The certificate is self-signed or not valid for the host name used; see "Network access and encryption" |
| `0 notes` in the MCP add-on | The passphrase there does not match the one in Obsidian |
| MCP add-on says "N documents could not be read" | The encryption salt is missing, typically after a replication that skipped `_local` documents. See "Moving an existing database here" |
