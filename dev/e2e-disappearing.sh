#!/usr/bin/env bash
# End-to-end test: room auto-delete
# Requires: dev/run.sh server running.
#
# 1. Register alice and bob; alice creates a room (she is its admin) and invites bob, who joins
# 2. Send message A (auto-delete still off), set ttl=10 seconds, then send message B and attachment C
# 3. After 20 seconds, check that:
#    - bob, a regular member, cannot change auto-delete; alice, the admin, can
#    - A is not deleted (messages sent before it was turned on are unaffected)
#    - B and C carry the com.freechat.expires_at marker when sent (clients delete their own copies from it)
#    - after expiry B and C are gone from the server (no redaction left), and C's file is deleted
#    - the room keeps working after its newest event is removed
#    - sliding sync returns the com.freechat.disappearing state even when the client did not ask for it
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

echo "Registering users..."
ALICE=$(register "alice$SUFFIX")
BOB=$(register "bob$SUFFIX")
BOB_ID="@bob$SUFFIX:localhost"

echo "Creating the room..."
ROOM=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"invite\":[\"$BOB_ID\"]}" | j 'd["room_id"]')
R=$(urlenc "$ROOM")
api "$BOB" POST "/join/$R" '{}' >/dev/null

EV_A=$(send_text "$ALICE" "$ROOM" before)

echo "Permissions..."
check "bob, a regular member, cannot change auto-delete (403)" "[[ \$(api_status '$BOB' PUT '/rooms/$R/state/com.freechat.disappearing/' '{\"ttl\":10}') == 403 ]]"
check "alice, the admin, can turn on auto-delete with ttl=10s" "[[ \$(api_status '$ALICE' PUT '/rooms/$R/state/com.freechat.disappearing/' '{\"ttl\":10}') == 200 ]]"

EV_B=$(send_text "$BOB" "$ROOM" secret)

MXC=$(curl -s -X POST "$HS/_matrix/media/v3/upload?filename=x.txt" -H "Authorization: Bearer $ALICE" \
	-H 'Content-Type: text/plain' --data-binary 'attachment' | j 'd["content_uri"]')
EV_C=$(api "$ALICE" PUT "/rooms/$R/send/m.room.message/$(txn)" \
	"{\"msgtype\":\"m.file\",\"body\":\"x.txt\",\"url\":\"$MXC\"}" | j 'd["event_id"]')
MEDIA_PATH="${MXC#mxc://}"
BJ=$(event_json "$ALICE" "$ROOM" "$EV_B")
SENT=$(echo "$BJ" | j 'd["origin_server_ts"]')
check "the message carries the expiry marker (sent time + 10 s)" "[[ \$(echo '$BJ' | j 'd[\"unsigned\"].get(\"com.freechat.expires_at\")') == \$((SENT + 10000)) ]]"
check "the message sent before it was on has no expiry marker" "[[ \$(event_json '$ALICE' '$ROOM' '$EV_A' | j 'd.get(\"unsigned\", {}).get(\"com.freechat.expires_at\")') == None ]]"
media_status() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ALICE" "$HS/_matrix/client/v1/media/download/$MEDIA_PATH"; }

echo "Attachment status after upload: $(media_status)"
echo "Waiting 20 seconds..."
sleep 20

echo "Results:"
A=$(event_json "$ALICE" "$ROOM" "$EV_A")
gone() { [[ $(api_status "$ALICE" GET "/rooms/$R/event/$(urlenc "$1")") == 404 ]]; }
check "message A, sent before it was on, is still there" "[[ \$(echo '$A' | j 'd[\"content\"].get(\"body\", \"\")') == before ]]"
check "message B is gone from the server after expiry" "gone '$EV_B'"
check "attachment message C is gone after expiry" "gone '$EV_C'"
check "no redaction is left behind" "! api '$ALICE' GET '/rooms/$R/messages?dir=b&limit=100' | grep -q 'm.room.redaction'"
check "the attachment file is deleted from the server" "[[ \$(media_status) == 404 ]]"
check "the room keeps working after its newest event is removed" "[[ -n \$(send_text '$BOB' '$ROOM' after-purge) ]]"

# Element X (matrix-rust-sdk) cannot request custom state in sliding sync, so the server must add it
SS=$(curl -s -X POST "$HS/_matrix/client/unstable/org.matrix.simplified_msc3575/sync" \
	-H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
	-d '{"lists":{"all":{"ranges":[[0,20]],"required_state":[["m.room.name",""]],"timeline_limit":1}}}')
check "sliding sync returns the auto-delete setting without being asked" "[[ \$(echo '$SS' | j '[e[\"content\"].get(\"ttl\") for e in d[\"rooms\"][\"$ROOM\"][\"required_state\"] if e[\"type\"] == \"com.freechat.disappearing\"]') == '[10]' ]]"

# Every room is encrypted, public ones included
PUB=$(api "$ALICE" POST /createRoom '{"preset":"public_chat","visibility":"private"}' | j 'd["room_id"]')
check "public rooms get end-to-end encryption too" "[[ \$(api '$ALICE' GET '/rooms/$(urlenc "$PUB")/state/m.room.encryption/' | j 'd.get(\"algorithm\")') == m.megolm.v1.aes-sha2 ]]"

summary
