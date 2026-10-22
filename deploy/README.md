# Installing FreeChat

## What you need

1. A Linux server (VPS). **1 CPU core and 1 GB of memory are enough.** Supported systems:
   - Debian 11+, Ubuntu 20.04+
   - Fedora, CentOS Stream / RHEL / Rocky / Alma 8+
   - Arch, openSUSE, Alpine

   The CPU can be x86_64 or arm64.
2. A domain name with an **A record** pointing at the server's IP, e.g. `chat.example.com`.
   If you use Cloudflare, **turn off the orange-cloud proxy**, or calls cannot connect.
3. These ports open in your cloud provider's security group / firewall:
   - TCP `80`, `443`, `7881`
   - UDP `443`, `3478`, `50100-50200` (voice and video calls)

## Install

Log in to the server as root and run:

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh
```

The installer asks for your domain, an email address and the **message retention** (7 days by default), then:
- installs Docker
- on servers with less than 2 GB of memory, adds 2 GB of **encrypted** swap. It gets a new random key at every boot and the key is never written to disk, so after a reboot nothing left in the old swap (which may include decrypted messages) can be read. A plain `/swapfile` from an earlier install is replaced when you run the installer again. No swap is created on VPSes without disk encryption support (OpenVZ / LXC) or without systemd
- generates the secrets and configuration
- gets an HTTPS certificate
- configures the firewall (ufw / firewalld)
- starts all services

When it finishes, it shows the **registration token**. **The first account to register becomes the server admin.**

To skip the questions, pass everything at once:

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh \
  | sudo sh -s -- --domain chat.example.com --email you@example.com --retention 7d --yes
```

### Message retention

Whether or not a room has auto-delete on, no message stays on the server longer than this. When it runs out, the message is removed from the database for good (rooms, members and settings stay).
- Set it at install time, e.g. `7d` (7 days), `24h`, `30m`; `0` means no limit.
- Change it at any time with `freechat retention 3d`. It takes effect right away (the server restarts, which takes a few seconds), and messages older than the new limit are deleted immediately.
- `freechat retention` on its own shows the current setting.
- When a room's own auto-delete time is shorter, the shorter one applies.

### Private repositories and images (e.g. your own fork)

This repository and its images are public, so the commands above just work. If you fork the project and make the repository and images private, the files cannot be downloaded anonymously and `curl … | sh` does not work:

1. Create a **read-only token** on GitHub: Settings → Developer settings → Personal access tokens → Tokens (classic), with **only `read:packages`** ticked.
2. Copy `deploy/install.sh` to the VPS, e.g. from your computer: `scp deploy/install.sh root@YOUR_VPS_IP:/root/`.
3. On the VPS, run:

   ```bash
   sudo sh /root/install.sh --owner YOUR_GITHUB_USER --registry-user YOUR_GITHUB_USER
   ```

   The installer asks you to paste the read-only token (it is not shown while you type). The token can only download images, nothing else. It is kept in `/root/.docker/config.json` on the VPS for later `freechat update` runs.

### Optional: encrypted database volume

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh -s -- --encrypt-data
```

The database goes into a LUKS-encrypted volume (8 GB by default; write `--encrypt-data=20G` for another size).
- You type the passphrase during the install. **It is never stored on the server.**
- After every reboot, log in and run `freechat unlock` with the passphrase before the services start. While the volume is locked the server refuses to start instead of creating an empty database.
- **Protects against**: disk snapshots by the VPS provider, and disks that are taken or thrown away.
- **Does not protect against**: a provider that reads the memory of the running server.
- **Adding `--encrypt-data` to a server already in use**: the installer moves the database into the encrypted volume and deletes the old plaintext directory. Deleting does not overwrite the disk, so old messages may still be recoverable (tools such as `shred` cannot wipe SSDs or cloud disks reliably either). Earlier backups stay in `/opt/freechat/backups` unencrypted; delete them yourself. If that matters, install on a new server with `--encrypt-data` from the start.
- **If you forget the passphrase, the data is gone for good.**

## Day-to-day commands

| Command | What it does |
|---|---|
| `freechat status` | Show the services |
| `freechat debug-logs on` / `off` | Turn temporary debug logs on / off. **Nothing is logged by default** |
| `freechat logs` (or `freechat logs server`) | Show debug logs (run `debug-logs on` first) |
| `freechat unlock` / `freechat lock` | Unlock / lock the encrypted volume (installs with `--encrypt-data`) |
| `freechat update` | Update to the latest version |
| `freechat backup` | Back up the database, configuration and secrets to `/opt/freechat/backups/`. A backup holds the messages that had not expired when it was made, so **backups older than the message retention are deleted daily** (`freechat prune-backups`) |
| `freechat token` | Show the registration token |
| `freechat retention [age]` | Show / change how long messages are kept, e.g. `7d`, `24h`, `0` (no limit) |
| `freechat restart` | Restart |
| `freechat uninstall` | Stop the services (data is kept) |

**Running the installer again** regenerates the configuration and keeps the data and secrets. Use it to repair the configuration or change the domain.

## Android push notifications

FreeChat pushes go **through neither Google nor any phone maker**: the server runs its own push service, ntfy, and the ntfy app on the phone stays connected to it. A push only says "a room has new messages", with no content and no sender; FreeChat then fetches the messages from the server and decrypts them on the phone.

Set up each Android phone once:

1. Install the **ntfy** app from F-Droid, Google Play or GitHub (https://github.com/binwiederhier/ntfy-android/releases).
2. Open ntfy → menu at the top right → **Settings** → **Default server**, and enter `https://your-domain` (the same address as the FreeChat server). **You must change this**: otherwise pushes would go through ntfy's public server, and FreeChat refuses to use it.
3. Open FreeChat → Settings → Notifications and choose **ntfy** as the push method.
4. On phones that stop background apps aggressively (many Huawei, Xiaomi, OPPO, vivo, Honor and Samsung models), also let **ntfy** run in the background, or the system kills it:
   - **allow auto-start** (in the phone manager / app launch settings, switch to manual management and turn everything on)
   - **Battery → unrestricted / don't optimize**
   - **lock** ntfy in the recent apps (pull down or long-press its card and choose "Lock")

   Only ntfy needs this; FreeChat itself does not have to stay in the background.

FreeChat → Settings → Notifications → **Troubleshoot notifications** checks that pushes work.

> iPhones can only use Apple's push service, which is not supported yet; iOS push comes in a later version.

## What gets installed

| Service | Role | Public ports |
|---|---|---|
| `web` (Caddy + the FreeChat web client) | HTTPS, web client, reverse proxy | 80, 443 |
| `server` (the FreeChat homeserver) | messages, accounts, auto-delete, burn after reading | local only |
| `livekit` | relays voice and video (end-to-end encrypted, never recorded) | 7881/tcp, 3478/udp, 50100-50200/udp |
| `livekit-jwt` | call authorization | local only |
| `push` (ntfy) | Android push (only "new messages", no content; cached in memory for an hour) | local only (public through Caddy) |

Everything lives in `/opt/freechat`; the secrets are in `/opt/freechat/.env`.

## Privacy defaults

- Federation is off: the server talks to no other Matrix server
- **Every room, public ones included, is end-to-end encrypted**
- The original of a deleted message is not kept
- No call recording component
- No online status, no public room directory, no link previews
- The web client connects to no third party: no analytics, no error reporting, no integration manager, no Jitsi
- **Nothing is logged by default**: all container logs are discarded, and logs are only turned on temporarily to troubleshoot
- The server **records no IP addresses and no device names**; "last seen" is kept to the day only
- Expired messages are **removed from the database outright**, with no redaction left behind, so not even "someone sent a message at this time" remains; each device deletes its own copy when it connects
- Messages stay on the server for **at most 7 days** (set at install time; change it any time with `freechat retention`)
- Optional **encrypted database volume** (`--encrypt-data`)
- The web client keeps **chat history in memory only**: nothing goes to disk, closing the page drops it, and the next visit syncs from the server again. Drafts, sent history and runtime logs stay in memory too. Only the encryption keys are stored
- **Notifications only say "you have new messages"**: not who sent it, in which room, or what it says (phones keep notifications in their history). Message previews can be turned on in the settings
- On Android and iOS, chat history **does not outlive the app**: every launch drops the local message cache and syncs from the server again
- The web client, Android and iOS all offer **strict mode** (in the settings): not even the keys and the login stay on the device. Closing the app, or leaving it in the background for the chosen time, signs out and removes the device. If the app is killed before it can sign out, the server deletes the device once it has been idle for that long. Signing in again takes the password and the recovery key
- The web client follows the browser's language

## Troubleshooting

- **Finding a problem**: logs are off by default. Run `freechat debug-logs on`, reproduce the problem, look at `freechat logs web` or `freechat logs server`, then run `freechat debug-logs off`.
- **The certificate is not issued**: check that the domain points at the server and that ports 80 and 443 are open. Then run `freechat restart`.
- **Nothing works after a reboot**: if you installed with the encrypted volume, run `freechat unlock` first.
- **Chat works but calls do not connect**: check that UDP `3478`, `50100-50200` and TCP `7881` are open in your cloud provider's security group.
- **Local test install**: `sudo sh install.sh --local` installs to `https://freechat.localhost` with a self-signed certificate, no domain needed.
