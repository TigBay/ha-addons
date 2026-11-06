# Changelog

All notable changes to this add-on are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Security
- `sb_user` no longer has a default value. The add-on refuses to start until credentials are set, and the
  publicly known password `changeme` (the former default) is rejected instead of only logged as a warning.
  Installations that still use `admin:changeme` must set a new password before the add-on starts again.

## [2026.10.0] – 2026-11-01

### Added
- First release of the SilverBullet Home Assistant add-on
- Alpine base image `ghcr.io/home-assistant/base:3.23` (multi-arch, amd64 and aarch64)
- Static SilverBullet binary 2.12.1 from the official upstream image
- Web interface on port 3000 with mandatory authentication via `SB_USER`
- Persistent space path under `/share/silverbullet/space`
- Optional MCP bridge (silverbullet-ai-mcp@0.9.3) on port 3033
- Chromium for the Runtime API (enabled automatically when available)
- Automatic token generation for MCP when `mcp_token` is empty
- Health check via the `/.instance` endpoint
- Graceful shutdown via a SIGTERM handler (stop timeout 20 s)
- Detection of a crashed MCP bridge (e.g. missing plug `silverbullet-ai`) with an error message in the log
- AppArmor security profile (tested in enforce mode), access to `/share/silverbullet`
- German and English translations of the options and ports (`translations/`)
- Complete documentation with a local test procedure, instructions for installing the `silverbullet-ai` plug
  (Library Manager and manual) and a note on when the AppArmor profile is loaded
- Example home maintenance tracker (`examples/home-maintenance`) with Space Lua queries, all data fictional
- CI: lint (yamllint, shellcheck, hadolint, link check) and multi-arch build with publishing to GHCR;
  an already published version is not overwritten unless `force_push` is set

### Changed
- The build parameters live in the `Dockerfile` (default value of `BUILD_FROM`). The `build.yaml` that the
  Supervisor reports as deprecated is gone.
- The empty folder `rootfs/` is gone.

### Tested
- Home Assistant OS with Core 2026.10.4 on amd64 (built locally): web interface and authentication, reading and
  writing in the space, Runtime API, MCP bridge, clean stop and restart.
- Not tested: aarch64 on real hardware (CI builds the image), the browser view on Home Assistant, the watchdog on a
  real crash.
