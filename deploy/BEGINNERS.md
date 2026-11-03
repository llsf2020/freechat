# Setting up FreeChat, step by step

This guide is for people who have **never run a server before**. It explains every step, every word you will meet, and what to do when something goes wrong. If you have done this kind of thing before, the shorter [deployment guide](README.md) is enough.

Plan for about **an hour** the first time, most of it waiting.

---

## What you will have at the end

- Your own chat server at an address like `https://chat.example.com`
- An admin account on it (yours)
- Invite codes you can hand to the people you want to chat with
- Chat, voice and video calls in a web browser, and on Android phones

Nobody else runs this server: you do. Messages are end-to-end encrypted and deleted from the server after 7 days at most (you can change that).

---

## Words you will meet

| Word | What it means |
|---|---|
| **Server / VPS** | A computer in a data center that is always on and connected to the internet. You rent one by the month, like a phone plan. VPS means "virtual private server". |
| **IP address** | The server's number on the internet, e.g. `203.0.113.25`. |
| **Domain** | A name such as `example.com`, which you buy once a year. |
| **Subdomain** | A name under your domain, e.g. `chat.example.com`. It costs nothing extra. |
| **DNS record** | A setting at the company that sold you the domain, which says "this name means this IP address". |
| **Terminal** | A window where you type commands instead of clicking. |
| **SSH** | The way to open a terminal on the server from your own computer. |
| **root** | The administrator account on a Linux server. |
| **Port** | A numbered "door" on the server. Different services use different doors; the cloud company's firewall decides which doors are open. |

---

## Step 1. Rent a server

Any cloud or VPS company works. When you order, choose:

- **Size**: 1 CPU core and 1 GB of memory are enough for a family or a small group. 2 GB is more comfortable.
- **Disk**: 20 GB or more.
- **System (image)**: **Ubuntu 24.04 LTS** (Debian 12 also works). If you are asked, choose the **64-bit / x86_64** version, or **arm64** if the server is an ARM one.
- **Virtualization**: if the company offers both, choose **KVM**. Cheap "OpenVZ" or "LXC" servers work too, but without encrypted swap and without BBR (see below).
- **Location**: close to the people who will use the chat, for faster calls.
- **Login**: a root password (or an SSH key, if you already know what that is).

When the server is ready, the company's control panel shows its **public IP address**. Write down:

- the IP address, e.g. `203.0.113.25`
- the root password

> Use a **new, empty** server for FreeChat. If other websites already run on it, FreeChat cannot use the ports it needs.

---

## Step 2. Buy a domain

Buy any domain from a domain registrar, e.g. `example.com`. You do not need a new domain for every service: FreeChat will live on a **subdomain** such as `chat.example.com`.

In the rest of this guide, replace:
- `chat.example.com` with your own subdomain
- `203.0.113.25` with your server's IP address

---

## Step 3. Point the subdomain at the server

At the company where you bought the domain, open the **DNS** settings (sometimes called "DNS management", "DNS records" or "zone editor") and **add a record**:

| Field | What to enter |
|---|---|
| Type | `A` |
| Name / Host | `chat` (only the part before your domain) |
| Value / Points to / IPv4 address | your server's IP, e.g. `203.0.113.25` |
| TTL | leave the default (or 600 / 10 minutes) |

Save it.

**If your domain is on Cloudflare**: the record has an orange cloud icon next to it. **Click it so it turns grey ("DNS only")**. With the orange cloud, Cloudflare stands between your users and your server: calls cannot connect, and Cloudflare would see your traffic.

### Check that it works

The change takes from a minute to an hour to spread. On your own computer:

- **Windows**: press the Windows key, type `cmd`, press Enter, and in the black window type:
  ```
  nslookup chat.example.com
  ```
- **macOS**: open **Terminal** (press ⌘ + Space, type `Terminal`, press Enter) and type the same command.

When the answer shows your server's IP address, continue. If it shows nothing or another address, wait ten minutes and try again.

---

## Step 4. Open the ports

Most cloud companies block incoming connections until you allow them. In the control panel, find **Security group**, **Firewall** or **Network rules** for your server, and add these **inbound** rules (source: anywhere, `0.0.0.0/0`):

| Protocol | Port | Used for |
|---|---|---|
| TCP | `80` | getting the HTTPS certificate |
| TCP | `443` | the website and the apps |
| TCP | `7881` | calls (fallback) |
| UDP | `443` | faster web connections |
| UDP | `3478` | calls |
| UDP | `50100-50200` | calls (a range: enter it exactly like that) |

If your company has no such setting, all ports are probably open already. The installer also opens them in the server's own firewall.

---

## Step 5. Connect to the server

You now open a terminal **on the server**, from your computer.

### Windows 10 or 11

1. Press the Windows key, type `PowerShell`, press Enter.
2. Type (with your IP):
   ```
   ssh root@203.0.113.25
   ```
3. The first time, it asks `Are you sure you want to continue connecting (yes/no)?`. Type `yes` and press Enter.
4. It asks for the password. Type or paste the root password and press Enter. **Nothing appears while you type, not even dots. That is normal.** To paste in PowerShell, right-click.

### macOS

1. Open **Terminal** (⌘ + Space, type `Terminal`, Enter).
2. Do steps 2 to 4 above. To paste, press ⌘ + V.

### You are in when…

The line ends with something like `root@yourserver:~#`. Everything you type now runs on the server.

**If your company gave you a user other than root** (e.g. `ubuntu`), log in with `ssh ubuntu@203.0.113.25`, then type `sudo -i` and press Enter to become root.

---

## Step 6. Install FreeChat

Copy this whole line, paste it into the terminal, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh
```

It asks three questions:

1. **Your domain**: type `chat.example.com` (your subdomain, without `https://`) and press Enter.
2. **Contact email for HTTPS certificate notices**: optional. Let's Encrypt, the free certificate service, writes there only if your certificate has a problem. Press Enter to skip.
3. **Longest the server keeps any message**: press Enter for 7 days, or type e.g. `30d` for 30 days, `24h` for one day. You can change it later.

Then it works on its own for **5 to 15 minutes**: it installs Docker (the tool that runs FreeChat), sets up encrypted swap on small servers, turns on BBR (faster connections on long routes), downloads FreeChat, gets the HTTPS certificate and starts everything. Lines starting with `==>` tell you what it is doing. Lines starting with `warning:` are worth reading but usually not a problem.

At the end you see a box like this:

```
 Web client:          https://chat.example.com
 Server address:      https://chat.example.com   (enter this when signing in on the phone apps)
 Registration token:  4f9c2b7a1d0e8c3b5a6f7e21
                      For your own account; it never expires, so do not share it.
```

**Copy the whole box into a safe place** (a password manager or a note only you can read). You need the registration token in the next step.

> **Optional: encrypted database.** If you install with
> ```bash
> curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh -s -- --encrypt-data
> ```
> the database is kept in an encrypted volume, and the installer asks you to choose a passphrase. Then, **after every reboot of the server**, you must log in and type `freechat unlock` and your passphrase before FreeChat works again, and **if you forget the passphrase, all data is lost**. If you are not sure, leave it out: messages are end-to-end encrypted anyway.

---

## Step 7. Create your admin account

1. On your computer, open a browser and go to `https://chat.example.com`.
2. Click **Create account**.
3. Choose a **username** (e.g. `alice`; your full address becomes `@alice:chat.example.com`) and a **strong password**.
4. When it asks for a **registration token**, paste the one from the box.
5. You are in. **The first account is the server admin.**

### Save your recovery key

FreeChat asks you to **set up recovery** (or a "security key"). Do it, and keep the key or passphrase somewhere safe. Messages are encrypted on your devices: **without the recovery key, a new phone or a new browser cannot read your earlier messages**. The server cannot help, because it never has the keys.

You also find an **admin room** in your chat list ("chat.example.com Admin Room"). You can manage the server from there; see [Managing the server from the app](README.md#managing-the-server-from-the-app).

---

## Step 8. Invite people

Do **not** give anyone your registration token: it never runs out. Give each person an **invite code** instead. In the server terminal (log in again as in Step 5 if you closed it), type:

```bash
freechat invite
```

It prints a code that creates **one account within 7 days**. Send the person:

- the address: `https://chat.example.com`
- the invite code

They do Step 7 themselves, entering the invite code where it asks for a registration token.

More options:

| Command | What it does |
|---|---|
| `freechat invite --uses 5 --days 2` | a code for 5 accounts within 2 days |
| `freechat invite --uses 0 --days 1` | any number of accounts, but only within 1 day |
| `freechat invites` | the codes that can still be used |
| `freechat revoke CODE` | stop a code from working |

You can also make codes from the app, in the admin room: `!admin token issue --once --max-age 7d`.

---

## Step 9. Use it on a phone

**Any phone**: open `https://chat.example.com` in the phone's browser. Everything works there, including calls.

**Android app**: the project does not publish ready-made downloads yet. Test builds of the Android app are attached to the project's GitHub Actions runs (`android-release`). When you have the app:

1. Open it and choose to sign in on **another server** (the wording is like "Change account provider" or "Other").
2. Enter `https://chat.example.com`.
3. Sign in with your username and password, then confirm with your recovery key.

**New-message notifications on Android** work without any setup: the app checks about every 15 minutes. For instant notifications, open Settings → Notifications → Advanced settings → **Push notification provider** and choose **Built-in connection** (it shows a small permanent notification). See [Android push notifications](README.md#android-push-notifications) for the other choice, the ntfy app.

**iPhone app**: not available yet.

---

## Looking after the server

Log in as in Step 5, then:

| Command | When to use it |
|---|---|
| `freechat status` | See whether everything runs (every line should say `Up` or `running`) |
| `freechat update` | Install the latest FreeChat version. Do it about once a month |
| `freechat backup` | Save a backup in `/opt/freechat/backups/` |
| `freechat retention 3d` | Change how long messages stay on the server |
| `freechat restart` | Restart FreeChat |
| `freechat help` | Every command |

Also update the server's system now and then:

```bash
apt update && apt upgrade -y
```

(On Ubuntu and Debian. If it asks about restarting services, press Enter.) If it says a reboot is needed, type `reboot`, wait two minutes and check `freechat status`. With an encrypted database, run `freechat unlock` after the reboot.

---

## When something goes wrong

**The installer says the domain does not resolve.**
The DNS record is missing, wrong, or not spread yet. Check Step 3 with `nslookup`, wait, then run the install command again. Running it again is always safe: it keeps your data and settings.

**The website does not open, or the browser warns about the certificate.**
- Check that the domain points at the server (Step 3) and that TCP 80 and 443 are open (Step 4).
- On Cloudflare, make sure the cloud is **grey**.
- Then type `freechat restart` and wait two minutes.

**"port 80 is used by another program" (or 443).**
Something else runs on the server, often a web server that came with the image. Use a fresh server, or remove that program.

**Chat works but calls do not connect, or connect without sound.**
The UDP ports are closed. Check UDP `3478` and `50100-50200`, and TCP `7881`, in your cloud company's security group (Step 4).

**Nothing works after the server rebooted.**
If you installed with the encrypted database, type `freechat unlock`. Otherwise type `freechat status`, then `freechat restart`.

**I lost the registration token.**
Type `freechat token`. If you think someone else has it, type `freechat token rotate` to replace it.

**Someone forgot their password.**
In the admin room, send `!admin users reset-password @name:chat.example.com`. The server replies with a new password; give it to them privately. Their old encrypted messages need their recovery key.

**I need to see what is happening.**
Nothing is logged by default. Type `freechat debug-logs on`, try the thing that fails, look at `freechat logs server` or `freechat logs web` (press Ctrl + C to stop watching), then type `freechat debug-logs off`.

**`ssh` says "Connection refused" or "timed out".**
The server may still be starting, or SSH (TCP 22) is closed in the security group. Most companies also offer a "console" or "VNC" button in the control panel that opens a terminal in the browser.

---

## Keeping it safe

- **Never share** the root password, the registration token or anything in `/opt/freechat/.env`.
- Hand out **invite codes** that run out, not the registration token.
- Run `freechat update` and the system update regularly.
- Better than a root password: log in with an **SSH key**. Your cloud company's help pages explain how to add one.
- Keep your **recovery key** safe. Losing it means losing your old messages on new devices, and nobody can recover them.
