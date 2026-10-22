#!/usr/bin/env bash
# End-to-end test: server-wide retention cap (FREECHAT_MAX_RETENTION_SECS)
#
# The script restarts the local server itself (first without a cap, then with a 15-second cap); stop dev/run.sh server first.
#   1. Send an "old message" without a cap
#   2. Restart with a 1-second cap: the startup sweep removes the old message and the old attachment's file
#   3. A new message carries an expiry 15 seconds out and is gone afterwards; the room keeps working and keeps its state (name)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/dev/e2e-lib.sh"

SERVER_PID=""
start_server() { # start_server [CAP_SECS]
	FREECHAT_MAX_RETENTION_SECS="${1:-}" "$ROOT/dev/run.sh" server >"$ROOT/dev/server-retention.log" 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 60); do curl -sf "$HS/_matrix/client/versions" >/dev/null && return; sleep 1; done
	echo "the server did not start" >&2; exit 1
}
stop_server() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
	for _ in $(seq 1 30); do pgrep -x tuwunel >/dev/null || return 0; sleep 1; done
}
trap stop_server EXIT

pgrep -x tuwunel >/dev/null && { echo "stop the running server first" >&2; exit 1; }

echo "1. Starting without a cap, sending old messages..."
start_server
ALICE=$(register "ret$SUFFIX")
ROOM=$(api "$ALICE" POST /createRoom '{"preset":"private_chat","name":"retention-room"}' | j 'd["room_id"]')
R=$(urlenc "$ROOM")
OLD=$(send_text "$ALICE" "$ROOM" "old message")
MXC=$(curl -s -X POST "$HS/_matrix/media/v3/upload?filename=old.txt" -H "Authorization: Bearer $ALICE" \
	-H 'Content-Type: text/plain' --data-binary 'old attachment' | j 'd["content_uri"]')
OLD_FILE=$(api "$ALICE" PUT "/rooms/$R/send/m.room.message/$(txn)" \
	"{\"msgtype\":\"m.file\",\"body\":\"old.txt\",\"url\":\"$MXC\"}" | j 'd["event_id"]')
# One more message after the attachment, so the attachment goes through the history purge (the room's last message is expired on its own)
send_text "$ALICE" "$ROOM" "old tail" >/dev/null
media_status() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ALICE" "$HS/_matrix/client/v1/media/download/${MXC#mxc://}"; }
check "without a cap, messages carry no expiry marker" "[[ \$(event_json '$ALICE' '$ROOM' '$OLD' | j 'd.get(\"unsigned\", {}).get(\"com.freechat.expires_at\")') == None ]]"
sleep 2
stop_server

echo "2. Restarting with a 1-second cap (sweeping old messages)..."
start_server 1
sleep 8
check "the startup sweep removed the old message" "[[ \$(api_status '$ALICE' GET '/rooms/$R/event/$(urlenc "$OLD")') == 404 ]]"
check "the old attachment message is removed too" "[[ \$(api_status '$ALICE' GET '/rooms/$R/event/$(urlenc "$OLD_FILE")') == 404 ]]"
check "the old attachment's file is deleted from the server" "[[ \$(media_status) == 404 ]]"
check "the room state (name) is kept" "[[ \$(api '$ALICE' GET '/rooms/$R/state/m.room.name/' | j 'd[\"name\"]') == retention-room ]]"
stop_server

echo "3. Restarting with a 15-second cap (new messages expire by the cap)..."
start_server 15
NEW=$(send_text "$ALICE" "$ROOM" "new message")
NJ=$(event_json "$ALICE" "$ROOM" "$NEW")
SENT=$(echo "$NJ" | j 'd["origin_server_ts"]')
EXP=$(echo "$NJ" | j 'd["unsigned"].get("com.freechat.expires_at")')
check "the new message carries an expiry 15 seconds out" "[[ \$(( EXP - SENT )) -ge 14000 && \$(( EXP - SENT )) -le 15000 ]]"
check "messages can still be sent after the sweep" "[[ -n '$NEW' ]]"
sleep 25
check "the new message is gone after expiry" "[[ \$(api_status '$ALICE' GET '/rooms/$R/event/$(urlenc "$NEW")') == 404 ]]"
check "messages can still be sent afterwards" "[[ -n \$(send_text '$ALICE' '$ROOM' still-works) ]]"

summary
