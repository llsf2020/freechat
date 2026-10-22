#!/usr/bin/env bash
# End-to-end test: Android push (UnifiedPush + self-hosted ntfy)
#
# Start the local server first (dev/run.sh server) and have an ntfy binary ready:
#   NTFY_BIN=/path/to/ntfy dev/e2e-push.sh
# The script starts ntfy on port 8090 itself (configured like the installer: deny by default, only up* topics open) and stops it afterwards.
#   - bob registers a pusher (like Element X: event_id_only format, with ntfy's built-in Matrix gateway)
#   - alice messages bob, and the push arrives in the ntfy topic
#   - the push holds only room and event IDs: no message content, no sender name
#   - topics outside up* cannot be used (the server cannot serve as a public push service)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/dev/e2e-lib.sh"

NTFY_BIN="${NTFY_BIN:?set NTFY_BIN to the path of the ntfy binary}"
NTFY="http://localhost:8090"
WORK="$(mktemp -d)"
trap 'kill "$NTFY_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/server.yml" <<YML
base-url: "$NTFY"
listen-http: "127.0.0.1:8090"
auth-file: "$WORK/user.db"
auth-default-access: "deny-all"
auth-access:
  - "*:up*:rw"
visitor-subscriber-rate-limiting: true
web-root: "disable"
enable-signup: false
enable-login: false
cache-duration: "1h"
log-level: "warn"
YML
"$NTFY_BIN" serve --config "$WORK/server.yml" >"$WORK/ntfy.log" 2>&1 &
NTFY_PID=$!
for _ in $(seq 1 30); do curl -sf "$NTFY/v1/health" >/dev/null && break; sleep 0.5; done

echo "Registering users and creating the room..."
ALICE=$(register "pusha$SUFFIX")
BOB=$(register "pushb$SUFFIX")
BOB_ID="@pushb$SUFFIX:localhost"
ROOM=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"invite\":[\"$BOB_ID\"]}" | j 'd["room_id"]')
api "$BOB" POST "/join/$(urlenc "$ROOM")" '{}' >/dev/null

# Must be exactly "up" plus 12 characters (like the ntfy app), or ntfy does not treat it as a UnifiedPush topic and refuses the push (507)
TOPIC="up$(head -c 64 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"
check "the gateway reports itself as UnifiedPush's Matrix gateway" "[[ \$(curl -s '$NTFY/_matrix/push/v1/notify' | j 'd[\"unifiedpush\"][\"gateway\"]') == matrix ]]"
api "$BOB" POST /pushers/set "{\"kind\":\"http\",\"app_id\":\"io.element.android\",\"pushkey\":\"$NTFY/$TOPIC?up=1\",\"app_display_name\":\"FreeChat\",\"device_display_name\":\"phone\",\"lang\":\"en\",\"data\":{\"url\":\"$NTFY/_matrix/push/v1/notify\",\"format\":\"event_id_only\"}}" >/dev/null
check "bob's pusher is registered" "[[ \$(api '$BOB' GET /pushers | j 'len(d[\"pushers\"])') == 1 ]]"

# Like the ntfy app on the phone: an open subscription. ntfy only accepts UnifiedPush messages for topics
# with an active subscriber, which also charges rate limits to that subscriber instead of the homeserver.
curl -sN "$NTFY/$TOPIC/json" > "$WORK/received" &
SUB_PID=$!
sleep 1

echo "alice sends a message..."
EV=$(send_text "$ALICE" "$ROOM" "super secret body")
sleep 3
kill "$SUB_PID" 2>/dev/null || true
PUSHES=$(grep '"event":"message"' "$WORK/received" || true)
echo "  push content: $(echo "$PUSHES" | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["message"])' 2>/dev/null)"
check "ntfy received the push" "[[ -n '$PUSHES' ]]"
check "the push carries the message's event ID" "[[ '$PUSHES' == *'$EV'* ]]"
check "the push has no message content" "[[ '$PUSHES' != *'super secret body'* ]]"
check "the push has no sender" "[[ '$PUSHES' != *'pusha$SUFFIX'* ]]"

check "other topics cannot be published to (no public push service)" "[[ \$(curl -s -o /dev/null -w '%{http_code}' -d hi '$NTFY/notup$SUFFIX') == 403 ]]"
check "other topics cannot be subscribed to" "[[ \$(curl -s -o /dev/null -w '%{http_code}' '$NTFY/notup$SUFFIX/json?poll=1') == 403 ]]"

summary
