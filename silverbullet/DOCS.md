# SilverBullet add-on – documentation

## Overview

**SilverBullet** is a self-hosted, open-source note-taking and knowledge management system built entirely on Markdown files. All data stays local on your Home Assistant server — no cloud, no external services.

## Getting started

### 1. Configuration

Open the add-on configuration and adjust the following values:

| Option | Default | Description |
|--------|---------|-------------|
| `sb_user` | `admin:changeme` | Username and password in the format `user:password` |
| `space_path` | `/share/silverbullet/space` | Path to your Markdown files |
| `enable_mcp` | `false` | Enable the MCP bridge for AI access |
| `mcp_token` | *(empty)* | Bearer token for MCP. Empty = generated automatically |
| `additional_args` | *(empty)* | Optional additional SilverBullet arguments |

> **Important:** Change the default password `changeme` right after the installation.

### 2. Start the add-on

Click **Start**. The web interface is reachable at `http://<your-ha-ip>:3000` after a few seconds (after updates or on the first start it can take up to a minute).

When stopping, the add-on has up to 20 seconds (`timeout` in `config.yaml`) to shut down cleanly.

### 3. Data path

All Markdown files are stored under `/share/silverbullet/space`. This path is visible as a normal folder in the Home Assistant file system (reachable through the Samba or SSH add-on).

> **Note:** SilverBullet creates the file `.silverbullet.auth.json` in the space (login and lockout data, permissions 600). Do not delete it, do not share it via Samba and do not pass it on.

## Backup strategy

### Automatic Home Assistant backups
- The add-on configuration directory (`/data`) is backed up automatically with every Home Assistant backup.
- The SilverBullet space under `/share/silverbullet/space` is part of the **full Home Assistant backup** (not of the partial backup).

### Recommendation
Create regular **full** Home Assistant backups to also protect the space. Or enable an external backup service in the Home Assistant backup configuration.

## MCP integration (Claude Code / Claude app)

The optional MCP bridge allows AI assistants such as Claude Code to interact directly with your SilverBullet space.

### Activation

1. Set in the configuration:

   ```yaml
   enable_mcp: true
   mcp_token: "your-secure-token"  # Empty = generated automatically
   ```

2. Under **Network**, enter a port for `3033/tcp` (e.g. `3033`). The MCP port is disabled by default; without this mapping the bridge is not reachable from outside.
3. Restart the add-on.

> **Set the token yourself:** If `mcp_token` stays empty, a token is generated and stored in `/data/mcp_token.txt`. This add-on data directory is reachable neither through the Samba nor through the SSH add-on. So it is best to set the token yourself.

> **Requirements for MCP:**
> - Node.js ≥ 20 (installed automatically with the add-on)
> - Chromium (installed automatically with the add-on)
> - The plug **silverbullet-ai** must be installed in the SilverBullet space (see below and https://ai.silverbullet.md/)

### Install the `silverbullet-ai` plug

The bridge needs the plug in the space. After the installation, **restart** the add-on so the bridge finds the plug.

**Recommended: Library Manager** (according to the documentation of [silverbullet-ai](https://github.com/justyns/silverbullet-ai) from SilverBullet 2.11.0; not tested with this add-on):

1. Open the command palette in SilverBullet and run `Library: Install`.
2. Enter `ghr:justyns/silverbullet-ai/PLUG.md` (latest release) or `ghr:justyns/silverbullet-ai@0.9.3/PLUG.md` (version 0.9.3).
3. If an older version is still in `_plug/`, delete it first (hint from the plug documentation).

**Alternative: manually** (this way was tested with this add-on, plug 0.9.3 in SilverBullet 2.12.1): put the two files from [release 0.9.3](https://github.com/justyns/silverbullet-ai/releases/tag/0.9.3) into the space, e.g. in the Terminal & SSH add-on:

```bash
cd /share/silverbullet/space
mkdir -p _plug Library/justyns
curl -fsSL -o _plug/silverbullet-ai.plug.js \
  https://github.com/justyns/silverbullet-ai/releases/download/0.9.3/silverbullet-ai.plug.js
curl -fsSL -o Library/justyns/silverbullet-ai-library.md \
  https://github.com/justyns/silverbullet-ai/releases/download/0.9.3/silverbullet-ai-library.md
```

The plug is licensed under the AGPL-3.0, see the silverbullet-ai repository.

### Connect Claude Code

```bash
claude mcp add --transport http silverbullet http://<ha-ip>:3033/mcp \
  --header "Authorization: Bearer <your-token>"
```

> **The MCP bridge does not run without the `silverbullet-ai` plug.** It exits shortly after the start, while SilverBullet itself keeps running normally. The log shows:
> `MCP bridge exited. Is the plug 'silverbullet-ai' installed in the space? See DOCS.md.`
> Install the plug and restart the add-on.

> **Security warning:** The MCP endpoint must never be publicly reachable without a token. Use it only on the local network or through a secured tunnel (e.g. Tailscale).

## Troubleshooting

### SilverBullet does not start
- Check the logs: **Add-on → Log**
- Make sure port 3000 is not used by another application
- Check that `/share` is mounted in the add-on container

### No access to the web interface
- Check that `sb_user` is set correctly (format: `user:password`)
- Check the firewall settings of your network

### The MCP bridge does not respond
- Make sure `enable_mcp: true` is set
- Check that port 3033 is mapped under **Network** and reachable in your network
- Set `mcp_token` yourself if you do not know the automatically generated token
- Check that the plug **silverbullet-ai** is installed in the SilverBullet space
- Search the log for `MCP bridge exited`: the bridge crashes without the plug

### Health check
The add-on uses the endpoint `/.instance` for the health check (not `/ping`).
If the add-on does not start, check:
- Port 3000 is not in use
- `/share` is mounted in the add-on
- The health endpoint answers with HTTP 200

## Developer notes

### Test locally (without Home Assistant)

For local tests without the Home Assistant Supervisor:

1. Create a test environment:
   ```bash
   mkdir -p /tmp/sb-addon-test/{data,share}
   ```

2. Create an `options.json`:
   ```bash
   cat > /tmp/sb-addon-test/data/options.json <<'EOF'
   {"sb_user":"admin:testpass123","space_path":"/share/silverbullet/space","enable_mcp":false,"mcp_token":"","additional_args":""}
   EOF
   ```

3. Build and start the add-on:
   ```bash
   docker build -t sb-test ./silverbullet
   docker run -d --name sb-test -p 3000:3000 -p 3033:3033 \
     -v /tmp/sb-addon-test/data:/data -v /tmp/sb-addon-test/share:/share sb-test
   ```

4. Check the status:
   ```bash
   curl http://localhost:3000/.instance  # Should return HTTP 200
   ```

5. Check the authentication (the start page always shows the login page, the protection is visible at `/.fs/`):
   ```bash
   TOKEN=$(docker exec sb-test cat /data/sb_auth_token.txt)
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/.fs/index.md                                # 401
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" http://localhost:3000/.fs/index.md  # 200
   ```

6. Stop the container (should end with exit 0 within a few seconds):
   ```bash
   time docker stop sb-test; docker inspect sb-test --format 'exit {{.State.ExitCode}}'
   ```

> **Note:** The generated token is stored in `/data/sb_auth_token.txt` inside the container. It cannot be seen in the add-on log. For API calls: `docker exec sb-test cat /data/sb_auth_token.txt`.
>
> Without a Supervisor, bashio reports several errors on startup (`Failed to get addon config from Supervisor API`). That is expected; `run.sh` then reads the options directly from `/data/options.json`.

### Test as a local app in Home Assistant

In recent Home Assistant versions, add-ons are called "apps". This is how you test a state for which no published image exists yet:

1. Copy the folder `silverbullet/` to your Home Assistant:
   - with the **Samba add-on** into the share `addons` (folder `addons/silverbullet/`), or
   - in the **Terminal & SSH add-on**, local apps live under `/local_apps/silverbullet/` (no longer under `/addons`).
2. In the copied `config.yaml`, comment out the line `image:`. Then the Supervisor builds the image itself instead of pulling it from GHCR. The base image is the default value of `BUILD_FROM` in the `Dockerfile`; there is no `build.yaml` anymore.
3. Go to **Settings → Apps** and reload the store with **⋮**. The app appears among the local apps (menu names can differ depending on the Home Assistant version). Its slug is `local_silverbullet`.
4. Install it. The build takes a few minutes because of Chromium and Node.js (about four minutes on the amd64 test system, probably much longer on a Raspberry Pi).

After changing the files, choose **Rebuild** in the app so the Supervisor rebuilds the image. You can read the log in the UI or with the CLI: `ha apps logs local_silverbullet`.

> **Changing the AppArmor profile:** Home Assistant loads the profile `apparmor.txt` only on **installation**. After changing it, **Rebuild** is not enough. The app must be **uninstalled and installed again**. The space under `/share/silverbullet` is kept, `/data` (e.g. an automatically generated MCP token) is not. Note down your options beforehand.

## Security notes

- SilverBullet **never runs without authentication** (`sb_user` is mandatory)
- The MCP token is **not written to the logs**
- Automatically generated tokens are stored in `/data/mcp_token.txt` with permissions 600
- **Recommendation:** Set your own `mcp_token` in the configuration so the token is easier to manage.
- Which tools Claude may use through MCP (e.g. deleting pages) is determined by the plug `silverbullet-ai` and the bridge, not by this add-on. Only give Claude access to a space whose contents it may see and change.
