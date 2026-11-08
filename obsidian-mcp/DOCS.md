# Obsidian MCP Server add-on – documentation

## Overview

This add-on exposes an end-to-end encrypted Obsidian LiveSync vault to an AI
assistant over the [Model Context Protocol](https://modelcontextprotocol.io/).
It reads and writes notes directly in CouchDB — Obsidian does not have to be
open, and the laptop does not have to be on.

It runs [obsidian-sync-mcp](https://github.com/es617/obsidian-sync-mcp) v0.10.0
and needs the **Obsidian LiveSync Server** add-on (or another CouchDB) as its
backend.

> **Unofficial:** a community add-on, not affiliated with Obsidian,
> Self-hosted LiveSync or obsidian-sync-mcp.

## What it can do

| Tool | Purpose |
|---|---|
| `read_note`, `write_note`, `edit_note` | read, create and patch notes |
| `list_notes`, `list_folders`, `list_tags` | browse the vault |
| `search_notes` | full-text search, up to 20 search terms, up to 20 hits |
| `move_note`, `delete_note`, `get_note_metadata` | housekeeping |

`edit_note` replaces a passage instead of rewriting the file, so frontmatter
and formatting stay intact.

Two limits are worth knowing before you plan around this add-on:

- **`search_notes` returns at most 20 hits.** With a large vault and a common
  term the list is silently truncated.
- **`list_notes` cannot filter by frontmatter.** Folder, name, tag and
  modification date only. A query like "status = applied **and** date in
  October" is not expressible on the server; it has to go through full-text
  search.

## Getting started

### 1. Configuration

| Option | Default | Description |
|---|---|---|
| `couchdb_url` | `http://local-obsidian-couchdb:5984` | The CouchDB add-on. See "Reaching the other add-on" |
| `couchdb_user` | `obsidian` | Same as `admin_user` there |
| `couchdb_password` | *(empty)* | **Required** |
| `couchdb_database` | `obsidian` | Same as `database` there |
| `passphrase` | *(empty)* | The LiveSync end-to-end encryption passphrase |
| `id_derivation_key` | *(empty)* | Recovery code (`sls-id-v1:…`) when path obfuscation is on |
| `case_sensitive` | `false` | Must match the LiveSync setting |
| `auth_token` | *(empty)* | **Required.** Bearer token for the MCP endpoint |
| `base_url` | *(empty)* | Public HTTPS URL, needed for OAuth clients |
| `write_folders` | *(empty)* | Limits write access. Empty = the whole vault |
| `ssl` | `false` | Serve the endpoint over HTTPS on port 8443 |
| `certfile` | `fullchain.pem` | Certificate (PEM, full chain) under `/ssl` |
| `keyfile` | `privkey.pem` | Private key (PEM) under `/ssl` |
| `log_level` | `info` | |

Generate the token with something like `openssl rand -hex 32`. The add-on
refuses to start without one: the endpoint would otherwise give anyone who
reaches it read and write access to the whole vault.

### 2. Reaching the other add-on

Add-ons talk to each other by hostname, and the hostname depends on how the
add-on was installed:

| Installed as | `couchdb_url` |
|---|---|
| Local add-on (folder copied to `/local_apps`) | `http://local-obsidian-couchdb:5984` (verified on Home Assistant OS 18.4) |
| From this repository in the store | `http://<repo-hash>-obsidian-couchdb:5984` (not verified yet) |
| Any other CouchDB | its own URL |

If the name is wrong, the add-on stops after 120 seconds with a message naming
exactly this. The LiveSync Server add-on no longer publishes plain HTTP on the
host, so the host address with port 5984 is not a fallback any more; find the
hostname instead (the Supervisor shows it on the add-on's *Info* page).

### 3. The passphrase

If your vault is end-to-end encrypted — and it should be — the passphrase here
must be **character for character** the one in the Obsidian plugin. It also has
to be set **before** the first start.

> **This is the one real security trade-off of the setup.** The passphrase sits
> in clear text in the add-on configuration, so this server can decrypt the
> vault. Whoever gains access to the host can read every note. The encryption
> protects the transport and the database — not this machine.

A wrong or missing passphrase does not produce a clear error. The server
reports `0 notes` and `ChangeManager Error watching changes`, neither of which
names the cause.

### 4. Connecting a client

The server itself speaks plain HTTP on port 8787, and every request carries
the bearer token; every answer carries decrypted notes. Port 8787 is therefore
never published on the host: it is only for tunnel and proxy add-ons on the
internal network. The add-on asks the Supervisor at every start whether 8787
has a host port under *Network*, and does not start if it has — or if the
Supervisor cannot be asked.

**In your network, with a token** — over HTTPS on port 8443:

1. Put a certificate and its key into `/ssl`, for example with the Let's
   Encrypt or DuckDNS add-on. It must be valid for the host name your
   clients use.
2. Set `ssl: true` (and `certfile`/`keyfile` if your files have other names).
3. Under *Network*, enter a host port for **8443/tcp**. Leave 8787/tcp empty.
4. In `claude_desktop_config.json` or `.mcp.json`, add an HTTP MCP server at
   `https://<host-name-in-the-certificate>:8443/mcp` with the header
   `Authorization: Bearer <auth_token>`.

The HTTPS listener is a small TLS terminator in the add-on
(`tls-proxy.mjs`, Node built-ins only) that forwards each request unchanged to
the server on 8787 inside the container.

**From claude.ai, over OAuth** — the server brings its own OAuth 2.1 provider
with discovery, dynamic client registration and PKCE, which is what
claude.ai expects from a remote MCP server. It needs two things:

1. `base_url` set to the **public HTTPS** URL of the endpoint.
2. That URL actually reachable from the internet — through a Cloudflare Tunnel,
   a reverse proxy with a certificate, or Tailscale Funnel. Point the tunnel or
   proxy add-on at this add-on's internal hostname and port 8787 (for a local
   add-on `http://local-obsidian-mcp:8787`; not yet verified), or at 8443 over
   HTTPS if it runs outside Home Assistant.

The Home Assistant Tailscale add-on is **not** enough on its own: its
`services` option only does Serve (inside the tailnet), not Funnel.

Without HTTPS the add-on warns at startup, and rightly so: OAuth tokens would
travel in clear text.

### 5. Limiting write access

`write_folders` is the cheapest safety net in this setup. With
`write_folders: Applications` an assistant may read the whole vault but write
only inside that folder:

```
Write access denied: 'Other/note.md' is outside the writable folders (Applications/).
```

## Backup

The search index and the issued OAuth tokens live under `/data/obsidian-mcp`
and are part of the add-on backup. Neither is irreplaceable: the index is
rebuilt from CouchDB in seconds (measured: 528 notes in 2.3 s on a laptop,
5.3 s on a Dell Wyse), and tokens can be reissued.

A Home Assistant backup also contains the add-on options, so the passphrase,
the auth token and the CouchDB password are in it in clear text unless the
backup itself is password-protected.

The notes themselves are **not** in this add-on's backup. They belong to
CouchDB.

## Known limitations

- **AppArmor is off** until a profile has been tested on real hardware.
- **Turn the watchdog on.** It is off after installation. On the add-on's
  *Info* page switch **Watchdog** on, otherwise the Supervisor never restarts
  a hung server. Not yet triggered on purpose for this add-on.
- **The add-on never creates the CouchDB database.** It waits for it and stops
  with an explanatory message if it is missing.
- **The log lags behind.** After a bulk import the log kept repeating
  `Search index saved to disk (527 notes)` while the index had already moved
  on. Every search answer starts with a line stating how current the index is
  (`Index caught up with CouchDB seq 1076 … 528 of 528 notes`) — trust that,
  not the log.
- **Reads do not depend on the search index.** A note written seconds ago is
  readable through `read_note` and `list_notes` even if the index has not
  caught up. Only `search_notes` depends on it. The statement that they go
  "straight to CouchDB" is wrong: after the remote database was deleted,
  `list_notes` kept answering, so the server reads from a local copy. Its
  exact nature is not verified.
- **Open conflicts are invisible.** When two devices change the same line of a
  note, CouchDB keeps two live revisions. `read_note` then returns the
  revision CouchDB picks as the winner, while `search_notes` and Obsidian may
  show the other one, and no answer mentions the conflict. `edit_note` builds
  on the winner and leaves the other revision untouched. Nothing is lost —
  both revisions stay readable — but resolve conflicts in Obsidian promptly.
  Edits on different lines are merged automatically.
- **Only built locally so far**, like the CouchDB add-on.
- **HTTPS is not yet verified on Home Assistant hardware.** In local Docker,
  an MCP `initialize` over HTTPS on 8443 succeeded with the token and answered
  401 without it, and server-sent events streamed through. The port check and
  the watchdog with 8787 unpublished are verified on Home Assistant OS.
- **Plain HTTP stays inside the host.** Tunnel and proxy add-ons reach 8787
  over the internal Docker network in clear text. Reading that traffic needs a
  compromised add-on on the same machine, not just a seat on the LAN.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Stops with "auth_token is empty" | Set a token |
| Stops with "8787/tcp is published on host port …" | Clear the 8787/tcp field under *Network*; connect over 8443 or a tunnel. Typical after updating from 0.1.x |
| Stops with "Could not ask the Supervisor" | The Supervisor API did not answer. Restart the add-on; if it persists, check the Supervisor log |
| Stops with "/ssl/… does not exist" or "The HTTPS listener on 8443 …" | `ssl` is on but the certificate or key is missing, or they do not match |
| A local client stopped connecting after the update | 0.2.0 no longer serves `http://<ha-ip>:8787`. Use HTTPS on 8443; see "Connecting a client" |
| Stops with "CouchDB … did not answer" | `couchdb_url`, credentials or database name wrong, or the CouchDB add-on is not running |
| `0 notes`, `ChangeManager Error watching changes` | The passphrase does not match, or was empty at startup. The same message appears briefly while CouchDB restarts and then clears |
| "N documents could not be read" at the top of a search answer | The encryption salt is missing in CouchDB, for example after a replication that skipped `_local` documents. See the CouchDB add-on documentation |
| `search_notes` misses a brand new note | The index has not caught up; the first line of the answer says so |
| claude.ai will not connect | `base_url` is not a reachable public HTTPS URL |
