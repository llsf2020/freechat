# FreeChat

**English** | [简体中文](README.zh-CN.md)

A self-hosted, Telegram-like messenger with chat, voice and video (including group calls), plus **auto-delete and burn after reading**. It is built on the Matrix protocol, and every component is open source.

> ⚠️ The project is still in testing. The iOS app builds and passes its unit tests in CI, but has not been tried on a real device yet.

## Features

- **Auto-delete**: room admins pick a lifetime (1 hour to 1 month). When it runs out, the message is removed from the server database for good, with no redaction left behind, and every device deletes its local copy.
- **Burn after reading**: anyone can make their own messages disappear a set time after everyone has read them.
- **Server-wide retention cap**: no message stays on the server longer than this (set at install time, 7 days by default).
- **Private rooms**: joining takes a password or a request an admin approves.
- **Minimal metadata**: the server records no IP addresses or device names and keeps no logs by default. Pushes carry only an event ID, never content or sender. Android push runs through your own ntfy, not Google.
- **Strict mode**: the login session and keys live in memory only, and the device signs itself out when the app or page is closed.
- **Screenshot blocking**: Android can block screenshots and screen recording; iOS hides protected rooms while the screen is recorded.
- **One-script install**: a 1-core, 1 GB VPS is enough. HTTPS certificates are set up automatically, and the database can optionally live on an encrypted volume.

## Components

| Layer | Component | Modified |
|---|---|---|
| Server | Tuwunel (a Matrix homeserver written in Rust) | ✅ auto-delete, burn after reading, private rooms, metadata minimization, retention cap |
| Calls | LiveKit + lk-jwt-service + Element Call | used as released |
| Web | Element Web | ✅ UI for the above; messages kept in memory only; strict mode |
| Android | Element X Android | ✅ UI for the above; screenshot blocking; messages not kept across processes; strict mode |
| iOS | Element X iOS | ✅ the above, hidden while recording, app switcher cover, strict mode (not yet tried on a real device) |

Only **web, Android and iOS** are supported for now. Desktop apps (Windows, macOS, Linux) are not planned yet.

## Quick start

You need a Linux server and a domain name pointing at it. As root, run:

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh
```

Server requirements, firewall ports, options and day-to-day commands are in the [deployment guide](deploy/README.md).

## Repository layout

```
upstream.conf      upstream versions (baseline tag and its commit hash, verified at build time)
scripts/upstream.sh  check for new releases / sync upstream / export patches
forks/<name>/      a fork per component (separate git repos, not tracked here)
patches/<name>/    FreeChat's changes as patches (tracked here)
docker/            image builds: fetch the upstream baseline, apply patches, build-time checks
deploy/            the installer (it generates every config file on the server)
branding/          app name, package IDs and icon (edit here; builds pick it up)
dev/               local test environment
```

FreeChat's changes live as patches in `patches/`. A build downloads the upstream source listed in `upstream.conf`, checks the commit hash, then applies the patches.

## Documentation

- [Deployment guide](deploy/README.md)
- [Branding: name, package IDs, icon](branding/README.md)

## License

[AGPL-3.0](LICENSE). Each upstream component keeps its own license. As the AGPL requires, if you offer a modified version to others as a service, you must also offer them the corresponding source code.
