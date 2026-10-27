#!/bin/sh
# FreeChat one-step installer.
#
#   curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh
#
# Installs Docker if needed, then sets up the whole FreeChat stack in /opt/freechat:
# homeserver (Tuwunel + FreeChat patches), web client (Element Web + FreeChat patches, served by
# Caddy with automatic HTTPS), and calls (LiveKit + lk-jwt-service). Running it again upgrades the
# configuration and images while keeping data and secrets.
#
# Options (all optional; asked interactively when missing):
#   --domain example.com     domain pointing at this server (A/AAAA record)
#   --email you@example.com  contact for Let's Encrypt certificate notices
#   --yes                    do not ask questions; fail if something required is missing
#   --local                  local test install on https://freechat.localhost with a private CA
#   --retention AGE          longest the server keeps any message, e.g. 7d, 24h, 30m (default 7d; 0 = no cap).
#                            Change later with `freechat retention AGE`.
#   --brand NAME             name shown in the web client (default FreeChat; the apps take theirs from branding/)
#   --registry-user NAME     GitHub user for pulling private images (e.g. from your own private fork); the read-only token
#                            (scope read:packages) is asked for, or taken from FREECHAT_REGISTRY_TOKEN
#   --encrypt-data[=SIZE]    keep the database in a LUKS-encrypted volume (default 8G); after every reboot
#                            run `freechat unlock` and type the passphrase. It is never stored on the server.
#   --owner NAME             GitHub owner of the images (default: the one this script came from)
#   --tag TAG                image tag to install (default: latest)
#   --server-image IMAGE     override the homeserver image
#   --web-image IMAGE        override the web image
#
# Supported: Debian 11+, Ubuntu 20.04+, Fedora, CentOS Stream / RHEL / Rocky / Alma 8+, Arch,
# openSUSE, Alpine; x86_64 and arm64.
set -eu

FREECHAT_OWNER="${FREECHAT_OWNER:-llsf2020}"
DIR=/opt/freechat
# Pinned to the multi-arch index digest so a moved tag cannot change what runs.
LIVEKIT_IMAGE=livekit/livekit-server:v1.13.10@sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a
JWT_IMAGE=ghcr.io/element-hq/lk-jwt-service:0.9.0@sha256:d210fd778ba38b7e42e6fc64e8a24a7d66ccc3b938fb20d73bd713224af2dfea
NTFY_IMAGE=binwiederhier/ntfy:v2.28.0@sha256:6ef4b819f722fccdc036af611c4774cfdc2de821ab74fdd48bbf4c9d6f8973da
RTC_TCP_PORT=7881
RTC_UDP_START=50100
RTC_UDP_END=50200
TURN_UDP_PORT=3478

DOMAIN="" EMAIL="" ASSUME_YES=0 LOCAL=0 TAG=latest SERVER_IMAGE="" WEB_IMAGE="" ENCRYPT=0 VAULT_SIZE=8G REGISTRY_USER="" RETENTION="" BRAND=FreeChat

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Reads an answer from the terminal even when the script itself comes from a pipe.
ask() { # ask VAR "question" [default]
	_var="$1" _q="$2" _def="${3:-}"
	if [ "$ASSUME_YES" = 1 ] || [ ! -r /dev/tty ]; then
		eval "$_var=\$_def"
		return
	fi
	if [ -n "$_def" ]; then printf '%s [%s]: ' "$_q" "$_def" >/dev/tty; else printf '%s: ' "$_q" >/dev/tty; fi
	read -r _ans </dev/tty || _ans=""
	[ -n "$_ans" ] || _ans="$_def"
	eval "$_var=\$_ans"
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--domain) DOMAIN="$2"; shift 2 ;;
			--email) EMAIL="$2"; shift 2 ;;
			--yes|-y) ASSUME_YES=1; shift ;;
			--local) LOCAL=1; shift ;;
			--retention) RETENTION="$2"; shift 2 ;;
		--brand)
			BRAND="$2"
			case "$BRAND" in *'"'* | *\\* | '') die "--brand must not be empty or contain quotes or backslashes" ;; esac
			shift 2 ;;
			--registry-user) REGISTRY_USER="$2"; shift 2 ;;
			--encrypt-data) ENCRYPT=1; shift ;;
			--encrypt-data=*) ENCRYPT=1; VAULT_SIZE="${1#*=}"; shift ;;
			--owner) FREECHAT_OWNER="$2"; shift 2 ;;
			--tag) TAG="$2"; shift 2 ;;
			--server-image) SERVER_IMAGE="$2"; shift 2 ;;
			--web-image) WEB_IMAGE="$2"; shift 2 ;;
			-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
			*) die "unknown option: $1 (see --help)" ;;
		esac
	done
	owner=$(printf '%s' "$FREECHAT_OWNER" | tr '[:upper:]' '[:lower:]')
	[ -n "$SERVER_IMAGE" ] || SERVER_IMAGE="ghcr.io/$owner/freechat-server:$TAG"
	[ -n "$WEB_IMAGE" ] || WEB_IMAGE="ghcr.io/$owner/freechat-web:$TAG"
}

# ---------------------------------------------------------------------------------------------
# System detection and packages

detect_system() {
	[ "$(id -u)" = 0 ] || die "run as root (put sudo in front of the command)"
	[ -r /etc/os-release ] || die "cannot identify the system: /etc/os-release is missing"
	# shellcheck disable=SC1091
	. /etc/os-release
	OS_ID="${ID:-unknown}"
	OS_LIKE="${ID_LIKE:-}"
	case "$(uname -m)" in
		x86_64|amd64) ARCH=amd64 ;;
		aarch64|arm64) ARCH=arm64 ;;
		*) die "unsupported CPU architecture: $(uname -m) (only x86_64 and arm64)" ;;
	esac
	case " $OS_ID $OS_LIKE " in
		*" debian "*|*" ubuntu "*|*" raspbian "*) FAMILY=debian ;;
		*" fedora "*) FAMILY=fedora ;;
		*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*) FAMILY=rhel ;;
		*" arch "*|*" manjaro "*) FAMILY=arch ;;
		*" suse "*|*" opensuse "*|*" sles "*) FAMILY=suse ;;
		*" alpine "*) FAMILY=alpine ;;
		*) die "unsupported system: ${PRETTY_NAME:-$OS_ID}" ;;
	esac
	say "System: ${PRETTY_NAME:-$OS_ID} ($ARCH)"
}

pkg_install() {
	case "$FAMILY" in
		debian) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
		fedora|rhel) if have dnf; then dnf install -y -q "$@"; else yum install -y -q "$@"; fi ;;
		arch) pacman -Sy --noconfirm --needed "$@" ;;
		suse) zypper --non-interactive install "$@" ;;
		alpine) apk add --no-cache "$@" ;;
	esac
}

install_prerequisites() {
	missing=""
	for c in curl openssl; do have "$c" || missing="$missing $c"; done
	[ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || missing="$missing ca-certificates"
	if [ -n "$missing" ]; then
		say "Installing dependencies:$missing"
		# shellcheck disable=SC2086
		pkg_install $missing
	fi
}

install_docker() {
	if have docker && docker compose version >/dev/null 2>&1; then
		say "Docker already installed: $(docker --version)"
	else
		say "Installing Docker..."
		case "$FAMILY" in
			debian|fedora)
				curl -fsSL https://get.docker.com | sh ;;
			rhel)
				# get.docker.com does not know Rocky/Alma/Oracle; their CentOS repository works.
				pkg_install dnf-plugins-core || true
				dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
				pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
			arch) pkg_install docker docker-compose ;;
			suse) pkg_install docker docker-compose ;;
			alpine) pkg_install docker docker-cli-compose ;;
		esac
	fi
	if have systemctl && [ -d /run/systemd/system ]; then
		systemctl enable --now docker >/dev/null
	elif have rc-update; then
		rc-update add docker default >/dev/null 2>&1 || true
		rc-service docker start >/dev/null 2>&1 || true
	fi
	for _ in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 2; done
	docker info >/dev/null 2>&1 || die "Docker did not start"
	docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
}

# 1 GB machines need swap so image pulls and database compaction do not get OOM-killed.
# Swap holds whatever was in memory, decrypted messages and keys included, so it is encrypted
# with a random key made at every boot and never stored: after a reboot nothing in it can be read.
SWAP_FILE=/var/lib/freechat-swap
ensure_swap() {
	mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
	swap_mb=$(awk '/SwapTotal/ { print int($2 / 1024) }' /proc/meminfo)
	LOW_MEMORY=0
	[ "$mem_mb" -lt 2000 ] && LOW_MEMORY=1
	# Earlier installers made a plain /swapfile; it is replaced with the encrypted one.
	plain_swap=0
	grep -q '^/swapfile ' /etc/fstab 2>/dev/null && plain_swap=1
	[ -e /etc/systemd/system/freechat-swap.service ] && return 0
	if [ "$plain_swap" = 0 ] && { [ "$LOW_MEMORY" = 0 ] || [ "$swap_mb" -ge 1000 ]; }; then
		return 0
	fi

	if ! { have systemctl && [ -d /run/systemd/system ]; }; then
		[ "$plain_swap" = 1 ] && return 0
		warn "No systemd, so swap cannot be encrypted with a new key at every boot. No swap was created; set up encrypted swap yourself if memory runs short."
		return 0
	fi
	have cryptsetup || pkg_install cryptsetup >/dev/null 2>&1 || true
	[ -e /dev/mapper/control ] || modprobe dm_crypt 2>/dev/null || true
	if ! have cryptsetup || [ ! -e /dev/mapper/control ]; then
		if [ "$plain_swap" = 1 ]; then
			warn "This VPS does not support disk encryption; keeping the existing unencrypted /swapfile"
		else
			warn "This VPS does not support disk encryption (common on OpenVZ / LXC). No swap was created, so messages in memory are never written to disk"
		fi
		return 0
	fi

	if [ "$plain_swap" = 1 ]; then
		if swapoff /swapfile 2>/dev/null; then
			sed -i '\|^/swapfile |d' /etc/fstab
			rm -f /swapfile
		else
			warn "Not enough memory to turn off the old unencrypted /swapfile; reboot and run the installer again to switch to encrypted swap"
			return 0
		fi
	fi
	say "${mem_mb} MB of memory; creating 2 GB of encrypted swap (new key at every boot)..."
	if ! fallocate -l 2G "$SWAP_FILE" 2>/dev/null; then dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none; fi
	chmod 600 "$SWAP_FILE"
	cat > /etc/systemd/system/freechat-swap.service <<UNIT
[Unit]
Description=FreeChat encrypted swap (new random key at every boot)
DefaultDependencies=no
Before=docker.service swap.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom --keyfile-size 64 $SWAP_FILE freechat-swap && mkswap /dev/mapper/freechat-swap >/dev/null && swapon /dev/mapper/freechat-swap'
ExecStop=/bin/sh -c 'swapoff /dev/mapper/freechat-swap; cryptsetup close freechat-swap'

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload
	systemctl enable --now freechat-swap.service >/dev/null 2>&1 || warn "Encrypted swap did not start (see systemctl status freechat-swap)"
}

# Faster TCP on long or lossy routes (web pages, sync, media): BBR instead of the kernel's default congestion
# control. Calls use UDP and are not affected. Containers such as OpenVZ / LXC often cannot change it.
BBR_CONF=/etc/sysctl.d/90-freechat-bbr.conf
enable_bbr() {
	[ "$LOCAL" = 1 ] && return 0
	[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = bbr ] && return 0
	modprobe tcp_bbr 2>/dev/null || true
	if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		warn "This kernel has no BBR, or the VPS does not allow changing it (common on OpenVZ / LXC); keeping its TCP settings"
		return 0
	fi
	cat > "$BBR_CONF" <<EOF
# FreeChat: BBR congestion control, faster on long or lossy routes. Generated by install.sh.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
	# Where BBR is a module, load it at boot before the setting is applied.
	if [ -d /etc/modules-load.d ] && lsmod 2>/dev/null | grep -q '^tcp_bbr '; then
		echo tcp_bbr > /etc/modules-load.d/freechat-bbr.conf
	fi
	if sysctl -q -p "$BBR_CONF" >/dev/null 2>&1 && [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = bbr ]; then
		say "TCP congestion control: BBR (faster on long or lossy routes)"
	else
		rm -f "$BBR_CONF" /etc/modules-load.d/freechat-bbr.conf
		warn "Could not turn on BBR (the VPS does not allow it); keeping its TCP settings"
	fi
}

# ---------------------------------------------------------------------------------------------
# Configuration

choose_domain() {
	if [ "$LOCAL" = 1 ]; then
		DOMAIN=freechat.localhost
		return
	fi
	[ -n "$DOMAIN" ] || [ ! -f "$DIR/.env" ] || DOMAIN=$(sed -n 's/^DOMAIN=//p' "$DIR/.env")
	[ -n "$DOMAIN" ] || ask DOMAIN "Your domain (already pointing at this server, e.g. chat.example.com)"
	[ -n "$DOMAIN" ] || die "a domain is required (use --domain)"
	printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || die "invalid domain: $DOMAIN"
	[ -n "$EMAIL" ] || [ ! -f "$DIR/.env" ] || EMAIL=$(sed -n 's/^EMAIL=//p' "$DIR/.env")
	[ -n "$EMAIL" ] || ask EMAIL "Contact email for HTTPS certificate notices (optional)" ""
	choose_retention
}

# Converts 7d / 24h / 30m / 90s / 3600 to seconds; prints nothing for invalid input.
retention_secs() {
	num=${1%[dhms]}
	case "$num" in "" | *[!0-9]*) return 0 ;; esac
	case "${1#"$num"}" in d) mul=86400 ;; h) mul=3600 ;; m) mul=60 ;; *) mul=1 ;; esac
	echo $((num * mul))
}

choose_retention() {
	[ -n "$RETENTION" ] || [ ! -f "$DIR/.env" ] || RETENTION=$(sed -n 's/^RETENTION=//p' "$DIR/.env")
	[ -n "$RETENTION" ] || ask RETENTION "Longest the server keeps any message (e.g. 7d, 24h, 30m; 0 = no limit)" "7d"
	RETENTION_SECS=$(retention_secs "$RETENTION")
	[ -n "$RETENTION_SECS" ] || die "invalid retention: $RETENTION (examples: 7d, 24h, 30m)"
}

detect_public_ip() {
	if [ "$LOCAL" = 1 ]; then
		PUBLIC_IP=127.0.0.1
		return
	fi
	PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' | head -n1)
	case "$PUBLIC_IP" in
		""|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
			PUBLIC_IP="" ;; # behind NAT: let LiveKit discover it
	esac
	resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }')
	if [ -z "$resolved" ]; then
		warn "$DOMAIN does not resolve yet. Add an A record first, or the HTTPS certificate cannot be issued."
	elif [ -n "$PUBLIC_IP" ] && [ "$resolved" != "$PUBLIC_IP" ]; then
		warn "$DOMAIN resolves to $resolved, but this server's public IP is $PUBLIC_IP. If a CDN proxies it (such as Cloudflare's orange cloud), turn the proxy off."
	fi
}

load_or_create_secrets() {
	mkdir -p "$DIR/config" "$DIR/data/tuwunel" "$DIR/data/caddy" "$DIR/backups"
	chmod 700 "$DIR"
	if [ -f "$DIR/.env" ]; then
		REGISTRATION_TOKEN=$(sed -n 's/^REGISTRATION_TOKEN=//p' "$DIR/.env")
		LIVEKIT_KEY=$(sed -n 's/^LIVEKIT_KEY=//p' "$DIR/.env")
		LIVEKIT_SECRET=$(sed -n 's/^LIVEKIT_SECRET=//p' "$DIR/.env")
	fi
	[ -n "${REGISTRATION_TOKEN:-}" ] || REGISTRATION_TOKEN=$(openssl rand -hex 12)
	[ -n "${LIVEKIT_KEY:-}" ] || LIVEKIT_KEY="fc$(openssl rand -hex 9)"
	[ -n "${LIVEKIT_SECRET:-}" ] || LIVEKIT_SECRET=$(openssl rand -hex 32)
	umask 077
	cat > "$DIR/.env" <<EOF
# FreeChat install settings and secrets (keep private)
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SERVER_IMAGE=$SERVER_IMAGE
WEB_IMAGE=$WEB_IMAGE
LIVEKIT_IMAGE=$LIVEKIT_IMAGE
JWT_IMAGE=$JWT_IMAGE
NTFY_IMAGE=$NTFY_IMAGE
TUWUNEL_DATA=$TUWUNEL_DATA
BACKUP_DIR=$BACKUP_DIR
REGISTRATION_TOKEN=$REGISTRATION_TOKEN
LIVEKIT_KEY=$LIVEKIT_KEY
LIVEKIT_SECRET=$LIVEKIT_SECRET
RETENTION=$RETENTION
FREECHAT_MAX_RETENTION_SECS=$RETENTION_SECS
EOF
	umask 022
}

# Optional LUKS volume for the database. The passphrase is typed by the operator and never stored.
read_passphrase() { # read_passphrase VAR "prompt"
	[ -r /dev/tty ] || die "the encryption passphrase must be typed in a terminal"
	printf '%s' "$2" >/dev/tty
	stty -echo </dev/tty
	read -r _pw </dev/tty || _pw=""
	stty echo </dev/tty
	printf '\n' >/dev/tty
	eval "$1=\$_pw"
	unset _pw
}

setup_vault() {
	TUWUNEL_DATA=./data/tuwunel
	BACKUP_DIR=./backups
	if [ "$ENCRYPT" = 0 ] && [ ! -e "$DIR/vault.img" ]; then
		return
	fi
	TUWUNEL_DATA=./vault/tuwunel
	BACKUP_DIR=./vault/backups
	pass="" pass2=""
	{ have cryptsetup && have mkfs.ext4; } || pkg_install cryptsetup e2fsprogs
	[ -e /dev/mapper/control ] || modprobe dm_crypt 2>/dev/null || true
	[ -e /dev/mapper/control ] || die "this VPS does not support disk encryption (common on OpenVZ / LXC container VPSes); drop --encrypt-data"
	mkdir -p "$DIR/vault"

	if mountpoint -q "$DIR/vault"; then
		say "Encrypted volume already unlocked"
	elif [ -e "$DIR/vault.img" ]; then
		say "Unlocking the encrypted volume..."
		read_passphrase pass "Encrypted volume passphrase: "
		printf '%s' "$pass" | cryptsetup open --key-file - "$DIR/vault.img" freechat-vault || die "wrong passphrase"
		unset pass
		mount /dev/mapper/freechat-vault "$DIR/vault"
	else
		say "Creating a $VAULT_SIZE encrypted volume..."
		read_passphrase pass "Choose a passphrase for the encrypted volume (12+ characters; if you forget it the data is gone for good): "
		read_passphrase pass2 "Type it again: "
		[ "$pass" = "$pass2" ] || die "the passphrases do not match"
		[ "${#pass}" -ge 12 ] || die "passphrase too short"
		unset pass2
		truncate -s "$VAULT_SIZE" "$DIR/vault.img"
		chmod 600 "$DIR/vault.img"
		printf '%s' "$pass" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$DIR/vault.img"
		printf '%s' "$pass" | cryptsetup open --key-file - "$DIR/vault.img" freechat-vault
		unset pass
		mkfs.ext4 -q /dev/mapper/freechat-vault
		mount /dev/mapper/freechat-vault "$DIR/vault"
	fi
	mkdir -p "$DIR/vault/tuwunel" "$DIR/vault/backups"
	chmod 700 "$DIR/vault/backups"
	if [ -n "$(ls -A "$DIR/data/tuwunel" 2>/dev/null)" ] && [ -z "$(ls -A "$DIR/vault/tuwunel")" ]; then
		say "Moving the existing database into the encrypted volume..."
		(cd "$DIR" && docker compose --env-file .env stop server 2>/dev/null) || true
		cp -a "$DIR/data/tuwunel/." "$DIR/vault/tuwunel/"
		rm -rf "$DIR/data/tuwunel"
		mkdir -p "$DIR/data/tuwunel"
		# rm leaves the blocks on disk and SSDs remap them; shred is no better on SSDs, copy-on-write
		# filesystems or cloud disks, so we warn instead of pretending to wipe.
		warn "The old unencrypted database was deleted, but its contents may still be recoverable from the disk. If that matters, install on a new server with --encrypt-data from the start."
	fi
	if [ -n "$(ls -A "$DIR/backups" 2>/dev/null)" ]; then
		warn "$DIR/backups still holds backups from before encryption. They are not encrypted and are not pruned automatically. Once you no longer need them: rm -rf $DIR/backups/*"
	fi
}

write_configs() {
	cache_line=""
	[ "$LOW_MEMORY" = 1 ] && cache_line="cache_capacity_modifier = 0.5"

	cat > "$DIR/config/tuwunel.toml" <<EOF
# FreeChat homeserver. Generated by install.sh; rerun it to regenerate.
[global]
server_name = "$DOMAIN"
database_path = "/var/lib/tuwunel"
address = ["0.0.0.0"]
port = 8008
$cache_line

# Privacy: this server talks to nobody else.
allow_federation = false
trusted_servers = []

# Sign-up needs the registration token; the first account becomes the server admin.
allow_registration = true
registration_token = "$REGISTRATION_TOKEN"
grant_admin_to_first_user = true

# Encrypt every room, public ones included; never keep the original of deleted messages.
allow_encryption = true
encryption_enabled_by_default_for_room_type = "all"
save_unredacted_events = false

# No online status tracking; no public room directory; minimal logs.
allow_local_presence = false
allow_public_room_directory_without_auth = false
log = "warn"
log_colors = false
new_user_displayname_suffix = ""

[global.well_known]
client = "https://$DOMAIN"
livekit_url = "https://$DOMAIN/livekit/jwt"
EOF

	node_ip_lines="  use_external_ip: true"
	[ -n "$PUBLIC_IP" ] && node_ip_lines="  use_external_ip: false
  node_ip: $PUBLIC_IP"
	cat > "$DIR/config/ntfy.yml" <<EOF
# Android push via UnifiedPush. Generated by install.sh.
# Only the random up* topics that phones subscribe to can be used, so the server cannot be used as a
# public push service. Messages (event IDs only) are cached in memory for an hour, never on disk.
base-url: "https://$DOMAIN"
listen-http: ":80"
behind-proxy: true
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
auth-access:
  - "*:up*:rw"
# Rate limits count against the phone that subscribed, not against the homeserver sending the pushes.
visitor-subscriber-rate-limiting: true
cache-duration: "1h"
web-root: "disable"
enable-signup: false
enable-login: false
log-level: "warn"
EOF

	cat > "$DIR/config/livekit.yaml" <<EOF
# FreeChat call media server. Generated by install.sh.
port: 7880
bind_addresses: ["127.0.0.1"]
rtc:
  tcp_port: $RTC_TCP_PORT
  port_range_start: $RTC_UDP_START
  port_range_end: $RTC_UDP_END
$node_ip_lines
turn:
  enabled: true
  udp_port: $TURN_UDP_PORT
  domain: $DOMAIN
logging:
  level: warn
room:
  empty_timeout: 300
keys:
  $LIVEKIT_KEY: $LIVEKIT_SECRET
EOF

	tls_line=""
	email_line=""
	[ "$LOCAL" = 1 ] && tls_line="	tls internal"
	[ -n "$EMAIL" ] && email_line="	email $EMAIL"
	cat > "$DIR/config/Caddyfile" <<EOF
# FreeChat front end: HTTPS, web client and reverse proxy. Generated by install.sh.
{
$email_line
	admin off
}

$DOMAIN {
$tls_line
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		# The client must not be framed by other sites (clickjacking); Element Call frames it from the same origin.
		X-Frame-Options SAMEORIGIN
		# Browsers enforce this together with the <meta> CSP in Element's index.html, so this one only needs
		# to be stricter: nothing loads from or is sent to another site. The sha256 sources are the inline
		# scripts of the bundled Element Call page; docker/check-csp.py fails the web build when they change.
		Content-Security-Policy "frame-ancestors 'self'; default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'sha256-pQY0fuQAnnVQH5nQfjo80rzGkQzeN3JeAtAJ+1KcD4k=' 'sha256-3042zLa3JXvrJe/2n8P/XpIKwqBdNTu7fwbLZUNrzZQ='; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob: data:; connect-src 'self' wss://$DOMAIN blob:; frame-src 'self' blob:; worker-src 'self' blob:; font-src 'self' data:; form-action 'self'; base-uri 'self'; object-src 'none'"
		-Server
	}

	# Android push (UnifiedPush): ntfy serves the random up* topics the phone's ntfy app (or FreeChat's built-in
	# connection) subscribes to, its API, and the Matrix push gateway the homeserver posts to. Pushes carry event
	# IDs only.
	@push path /_matrix/push/* /v1/*
	handle @push {
		reverse_proxy 127.0.0.1:8090
	}
	@pushTopic path_regexp ^/up[A-Za-z0-9_-]+(/.*)?$
	handle @pushTopic {
		reverse_proxy 127.0.0.1:8090
	}
	@matrix {
		path /_matrix/* /.well-known/matrix/*
		not path /_matrix/push/*
	}
	handle @matrix {
		reverse_proxy 127.0.0.1:8008
	}
	handle_path /livekit/jwt/* {
		reverse_proxy 127.0.0.1:8081
	}
	handle_path /livekit/sfu/* {
		reverse_proxy 127.0.0.1:7880
	}
	handle /config.json {
		header Cache-Control no-cache
		root * /srv/web
		file_server
	}
	handle {
		root * /srv/web
		try_files {path} /index.html
		file_server
	}
}
EOF

	cat > "$DIR/config/element.json" <<EOF
{
    "default_server_config": {
        "m.homeserver": { "base_url": "https://$DOMAIN", "server_name": "$DOMAIN" }
    },
    "brand": "$BRAND",
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_3pid_login": true,
    "element_call": { "use_exclusively": true, "brand": "$BRAND" },
    "integrations_ui_url": "",
    "integrations_rest_url": "",
    "integrations_widgets_urls": [],
    "bug_report_endpoint_url": "",
    "show_labs_settings": false,
    "room_directory": { "servers": ["$DOMAIN"] },
    "features": { "feature_ask_to_join": true },
    "setting_defaults": {
        "urlPreviewsEnabled": false,
        "urlPreviewsEnabled_e2ee": false,
        "UIFeature.feedback": false,
        "UIFeature.thirdPartyId": false
    }
}
EOF

	cat > "$DIR/compose.yaml" <<'EOF'
# FreeChat services. Generated by install.sh; settings come from .env.
name: freechat

# Privacy: containers keep no logs anywhere. `freechat debug-logs on` enables small rotating logs
# temporarily (compose.override.yaml); `freechat debug-logs off` removes them again.
x-common: &common
  restart: unless-stopped
  logging:
    driver: none

services:
  server:
    <<: *common
    image: ${SERVER_IMAGE}
    ports: ["127.0.0.1:8008:8008"]
    environment:
      FREECHAT_MAX_RETENTION_SECS: ${FREECHAT_MAX_RETENTION_SECS:-0}
    volumes:
      # Never created on the fly: while the encrypted volume is locked the server refuses
      # to start instead of creating an empty database.
      - type: bind
        source: ${TUWUNEL_DATA}
        target: /var/lib/tuwunel
        bind: { create_host_path: false }
      - ./config/tuwunel.toml:/etc/tuwunel/tuwunel.toml:ro

  web:
    <<: *common
    image: ${WEB_IMAGE}
    network_mode: host
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./config/element.json:/srv/web/config.json:ro
      - ./data/caddy:/data

  livekit:
    <<: *common
    image: ${LIVEKIT_IMAGE}
    command: --config /etc/livekit.yaml
    network_mode: host
    volumes:
      - ./config/livekit.yaml:/etc/livekit.yaml:ro

  push:
    <<: *common
    image: ${NTFY_IMAGE}
    command: serve
    ports: ["127.0.0.1:8090:80"]
    volumes:
      - ./config/ntfy.yml:/etc/ntfy/server.yml:ro
    # Its access list is rebuilt from ntfy.yml on every start; nothing is kept on disk.
    tmpfs: ["/var/lib/ntfy"]

  livekit-jwt:
    <<: *common
    image: ${JWT_IMAGE}
    ports: ["127.0.0.1:8081:8081"]
    environment:
      LIVEKIT_JWT_BIND: ":8081"
      LIVEKIT_URL: wss://${DOMAIN}/livekit/sfu
      LIVEKIT_KEY: ${LIVEKIT_KEY}
      LIVEKIT_SECRET: ${LIVEKIT_SECRET}
      LIVEKIT_FULL_ACCESS_HOMESERVERS: ${DOMAIN}
EOF
	if [ "$LOCAL" = 1 ]; then
		# The JWT service checks logins against https://freechat.localhost, signed by Caddy's private CA.
		cat >> "$DIR/compose.yaml" <<'EOF'
      LIVEKIT_INSECURE_SKIP_VERIFY_TLS: YES_I_KNOW_WHAT_I_AM_DOING
    extra_hosts: ["freechat.localhost:host-gateway"]
EOF
	fi

	chown -R 10001 "$DIR/${TUWUNEL_DATA#./}"
}

open_firewall() {
	ports_tcp="80 443 $RTC_TCP_PORT"
	if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
		say "Configuring the firewall (ufw)..."
		for p in $ports_tcp; do ufw allow "$p/tcp" >/dev/null; done
		ufw allow 443/udp >/dev/null
		ufw allow "$TURN_UDP_PORT/udp" >/dev/null
		ufw allow "$RTC_UDP_START:$RTC_UDP_END/udp" >/dev/null
	elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		say "Configuring the firewall (firewalld)..."
		for p in $ports_tcp; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null; done
		firewall-cmd --permanent --add-port=443/udp >/dev/null
		firewall-cmd --permanent --add-port="$TURN_UDP_PORT/udp" >/dev/null
		firewall-cmd --permanent --add-port="$RTC_UDP_START-$RTC_UDP_END/udp" >/dev/null
		firewall-cmd --reload >/dev/null
	fi
}

check_ports_free() {
	have ss || return 0
	for p in 80 443; do
		if ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && ! docker ps --format '{{.Names}}' | grep -q '^freechat-web'; then
			die "port $p is used by another program (such as nginx or apache); stop it first"
		fi
	done
}

install_cli() {
	cat > /usr/local/bin/freechat <<'CLI'
#!/bin/sh
# FreeChat management. Run `freechat help` for the commands.
set -eu
DIR=/opt/freechat
cd "$DIR"
dc() { docker compose --env-file "$DIR/.env" "$@"; }
env_get() { sed -n "s/^$1=//p" "$DIR/.env"; }
BACKUP_DIR=$(env_get BACKUP_DIR)
BACKUP_DIR=${BACKUP_DIR:-./backups}
TUWUNEL_DATA=$(env_get TUWUNEL_DATA)
TUWUNEL_DATA=${TUWUNEL_DATA:-./data/tuwunel}

read_secret() {
	printf '%s' "$1" >/dev/tty
	stty -echo </dev/tty
	read -r secret </dev/tty || secret=""
	stty echo </dev/tty
	printf '\n' >/dev/tty
}

case "${1:-help}" in
	status) dc ps ;;
	logs)
		shift
		[ -f "$DIR/compose.override.yaml" ] || { echo "Logs are off by default (nothing is kept). To troubleshoot, first run: freechat debug-logs on"; exit 1; }
		dc logs --tail=200 -f "$@" ;;
	debug-logs)
		case "${2:-}" in
			on)
				cat > "$DIR/compose.override.yaml" <<'YAML'
# Temporary debug logs; remove with `freechat debug-logs off`.
x-debug-logs: &debug-logs
  logging: { driver: json-file, options: { max-size: "1m", max-file: "1" } }
services:
  server: *debug-logs
  web: *debug-logs
  livekit: *debug-logs
  livekit-jwt: *debug-logs
  push: *debug-logs
YAML
				dc up -d
				echo "Debug logs are on. When you are done, run: freechat debug-logs off" ;;
			off)
				rm -f "$DIR/compose.override.yaml"
				dc up -d --force-recreate
				echo "Debug logs are off; the old logs went with the containers" ;;
			*) echo "usage: freechat debug-logs on|off"; exit 1 ;;
		esac ;;
	unlock)
		[ -e "$DIR/vault.img" ] || { echo "there is no encrypted volume"; exit 1; }
		if ! mountpoint -q "$DIR/vault"; then
			read_secret "Encrypted volume passphrase: "
			printf '%s' "$secret" | cryptsetup open --key-file - "$DIR/vault.img" freechat-vault || { echo "wrong passphrase"; exit 1; }
			secret=""
			mount /dev/mapper/freechat-vault "$DIR/vault"
		fi
		dc up -d
		echo "Unlocked and started" ;;
	lock)
		[ -e "$DIR/vault.img" ] || { echo "there is no encrypted volume"; exit 1; }
		dc down
		if mountpoint -q "$DIR/vault"; then umount "$DIR/vault"; fi
		cryptsetup close freechat-vault 2>/dev/null || true
		echo "Stopped and locked; the data cannot be opened without the passphrase" ;;
	update) dc pull && dc up -d --remove-orphans && docker image prune -f >/dev/null && dc ps ;;
	restart) dc restart ;;
	token) env_get REGISTRATION_TOKEN ;;
	retention)
		if [ -z "${2:-}" ]; then
			cur=$(env_get RETENTION)
			echo "Longest the server keeps any message: ${cur:-0} (0 = no limit)"
			exit 0
		fi
		num=${2%[dhms]}
		case "$num" in "" | *[!0-9]*) echo "invalid value: $2 (examples: 7d, 24h, 30m, 0)"; exit 1 ;; esac
		case "${2#"$num"}" in d) mul=86400 ;; h) mul=3600 ;; m) mul=60 ;; *) mul=1 ;; esac
		secs=$((num * mul))
		tmp="$DIR/.env.tmp"
		grep -v '^RETENTION=\|^FREECHAT_MAX_RETENTION_SECS=' "$DIR/.env" > "$tmp"
		printf 'RETENTION=%s\nFREECHAT_MAX_RETENTION_SECS=%s\n' "$2" "$secs" >> "$tmp"
		chmod 600 "$tmp" && mv "$tmp" "$DIR/.env"
		dc up -d server
		echo "Done: messages are kept for at most $2. Older ones are deleted within a minute, then checked every hour." ;;
	backup)
		mkdir -p "$DIR/${BACKUP_DIR#./}"
		out="$DIR/${BACKUP_DIR#./}/freechat-$(date +%Y%m%d-%H%M%S).tar.gz"
		dc stop server
		tar -czf "$out" -C "$DIR" .env config "${TUWUNEL_DATA#./}" || { dc start server; exit 1; }
		dc start server
		chmod 600 "$out"
		echo "Backup written: $out"
		echo "Note: a backup holds the messages that had not expired when it was made. Backups older than the message retention are deleted automatically."
		"$0" prune-backups ;;
	prune-backups)
		# Backups must not keep messages longer than the server does.
		secs=$(env_get FREECHAT_MAX_RETENTION_SECS)
		case "$secs" in "" | 0 | *[!0-9]*) exit 0 ;; esac
		mins=$(( (secs + 59) / 60 ))
		find "$DIR/${BACKUP_DIR#./}" -maxdepth 1 -name 'freechat-*.tar.gz' -mmin +"$mins" -print -delete 2>/dev/null \
			| sed 's/^/Deleted expired backup: /' ;;
	uninstall)
		printf 'This stops FreeChat. Type yes to confirm: '
		read -r answer
		[ "$answer" = yes ] || exit 1
		dc down
		echo "Stopped. The data is still in $DIR; if you are sure you no longer need it: rm -rf $DIR" ;;
	*)
		cat <<'HELP'
usage: freechat <command>
  status              show the services
  update              update to the latest version
  restart             restart
  token               show the registration token
  retention [age]     show / change how long messages are kept, e.g. 7d, 24h, 30m; 0 = no limit
  backup              back up the database, configuration and secrets (inside the encrypted
                      volume when there is one); backups older than the retention go daily
  debug-logs on|off   turn temporary debug logs on / off (nothing is logged by default)
  logs [service]      show debug logs (run debug-logs on first)
  unlock / lock       unlock / lock the encrypted volume (installs with --encrypt-data)
  uninstall           stop the services (data is kept)
HELP
		;;
esac
CLI
	chmod 755 /usr/local/bin/freechat

	# Backups older than the retention cap are deleted daily, not only when a new backup is made.
	if have systemctl && [ -d /run/systemd/system ]; then
		cat > /etc/systemd/system/freechat-prune-backups.service <<'UNIT'
[Unit]
Description=FreeChat: delete backups older than the message retention

[Service]
Type=oneshot
ExecStart=/usr/local/bin/freechat prune-backups
UNIT
		cat > /etc/systemd/system/freechat-prune-backups.timer <<'UNIT'
[Unit]
Description=FreeChat: delete old backups daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT
		systemctl daemon-reload
		systemctl enable --now freechat-prune-backups.timer >/dev/null 2>&1 || true
	fi
}

# Private images (e.g. from a private fork): log Docker in to ghcr.io with a read-only token.
registry_login() {
	[ -n "$REGISTRY_USER" ] || return 0
	token="${FREECHAT_REGISTRY_TOKEN:-}"
	[ -n "$token" ] || read_passphrase token "GitHub read-only token (read:packages): "
	[ -n "$token" ] || die "a token is needed to pull private images"
	printf '%s' "$token" | docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null || die "could not log in to ghcr.io; check the user name and token"
	unset token
	say "Logged in to ghcr.io (credentials kept in /root/.docker/config.json for later updates)"
}

start_stack() {
	registry_login
	say "Pulling images (a few minutes the first time)..."
	(cd "$DIR" && docker compose --env-file .env pull --quiet)
	say "Starting services..."
	(cd "$DIR" && docker compose --env-file .env up -d --remove-orphans)

	say "Waiting for the services..."
	curl_opts="-fsS --max-time 5"
	[ "$LOCAL" = 1 ] && curl_opts="$curl_opts -k --resolve $DOMAIN:443:127.0.0.1"
	i=0
	# shellcheck disable=SC2086
	until curl $curl_opts "https://$DOMAIN/_matrix/client/versions" >/dev/null 2>&1; do
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			warn "Still not ready after 3 minutes. Common causes: the domain does not point at this server, or the cloud provider's security group blocks ports 80/443."
			warn "To troubleshoot: run freechat debug-logs on, then freechat logs web or freechat logs server"
			return 1
		fi
		sleep 3
	done
}

summary() {
	cat <<EOF

========================================================================
 FreeChat is installed
========================================================================
 Web client:          https://$DOMAIN
 Server address:      https://$DOMAIN   (enter this when signing in on the phone apps)
 Registration token:  $REGISTRATION_TOKEN
                      The first account to register becomes the server admin.
                      Show it again later: freechat token
 Message retention:   messages are kept for at most $RETENTION (0 = no limit); change: freechat retention 3d
 Android push:        works without setup (checks every 15 minutes); for instant pushes choose the
                      built-in connection, or install the ntfy app with "Default server" https://$DOMAIN

 Management:          freechat help  (status, update, backup, debug-logs, unlock/lock...)
 Logs:                nothing is logged by default; to troubleshoot run freechat debug-logs on

 Open these in your cloud provider's security group / firewall:
   TCP 80, 443, $RTC_TCP_PORT
   UDP 443, $TURN_UDP_PORT, $RTC_UDP_START-$RTC_UDP_END  (voice and video calls)

 Install directory:   $DIR (secrets in $DIR/.env; keep them private)
========================================================================
EOF
}

main() {
	parse_args "$@"
	detect_system
	install_prerequisites
	choose_domain
	detect_public_ip
	ensure_swap
	enable_bbr
	install_docker
	check_ports_free
	setup_vault
	load_or_create_secrets
	write_configs
	open_firewall
	install_cli
	start_stack || true
	summary
}

main "$@"
