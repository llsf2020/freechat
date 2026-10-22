#!/usr/bin/env bash
# End-to-end test: personal burn after reading
# Requires: dev/run.sh server running.
#
# bob sets read_ttl=3 seconds globally.
# Group chat (alice, bob, carol):
#   - bob sends M1; only alice reads it -> not deleted
#   - carol reads it too -> deleted 3 seconds later
#   - reading a later message counts for earlier ones (carol only sends a receipt for M3, and M2 goes too)
#   - a private read marker (m.read.private) counts as read
# Direct chat (bob, dave), where bob sets 0 for this chat only (off; kept under rooms in the global setting):
#   - not deleted even after dave reads it
# alice has it off -> her messages are not deleted when read
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

receipt() { # receipt TOKEN ROOM_ID EVENT_ID [TYPE]
	api "$1" POST "/rooms/$(urlenc "$2")/receipt/${4:-m.read}/$(urlenc "$3")" '{}' >/dev/null
}

echo "Registering users..."
ALICE=$(register "alice$SUFFIX"); BOB=$(register "bob$SUFFIX")
CAROL=$(register "carol$SUFFIX"); DAVE=$(register "dave$SUFFIX")
id() { echo "@$1$SUFFIX:localhost"; }

echo "bob turns on burn after reading globally, 3 seconds..."
api "$BOB" PUT "/user/$(urlenc "$(id bob)")/account_data/com.freechat.disappearing" '{"read_ttl":3}' >/dev/null

echo "Creating the group chat..."
GROUP=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"invite\":[\"$(id bob)\",\"$(id carol)\"]}" | j 'd["room_id"]')
api "$BOB" POST "/join/$(urlenc "$GROUP")" '{}' >/dev/null
api "$CAROL" POST "/join/$(urlenc "$GROUP")" '{}' >/dev/null

M1=$(send_text "$BOB" "$GROUP" one)
check "the message carries the burn-after-reading marker (3 s)" "[[ \$(event_json '$ALICE' '$GROUP' '$M1' | j 'd[\"unsigned\"].get(\"com.freechat.read_ttl\")') == 3 ]]"
receipt "$ALICE" "$GROUP" "$M1"
sleep 6
check "only some members read it, so it stays" "! is_redacted '$ALICE' '$GROUP' '$M1'"

receipt "$CAROL" "$GROUP" "$M1"
sleep 1
check "just read, the 3-second countdown has not run out" "! is_redacted '$ALICE' '$GROUP' '$M1'"
sleep 9
check "everyone else read it, so it is deleted 3 seconds later" "is_redacted '$ALICE' '$GROUP' '$M1'"
check "no redaction is left after deletion" "! api '$ALICE' GET '/rooms/$(urlenc "$GROUP")/messages?dir=b&limit=100' | grep -q 'm.room.redaction'"

M2=$(send_text "$BOB" "$GROUP" two)
M3=$(send_text "$BOB" "$GROUP" three)
A1=$(send_text "$ALICE" "$GROUP" alice-message)
receipt "$ALICE" "$GROUP" "$M3" m.read.private
receipt "$CAROL" "$GROUP" "$A1"
receipt "$BOB" "$GROUP" "$A1"
sleep 12
check "reading a later message counts as reading M2" "is_redacted '$ALICE' '$GROUP' '$M2'"
check "a private read marker counts as read, so M3 is deleted" "is_redacted '$ALICE' '$GROUP' '$M3'"
check "alice has burn after reading off, so her message stays" "! is_redacted '$ALICE' '$GROUP' '$A1'"

# Online devices ask the server whether marked messages still exist (with private read markers they cannot work it out)
EXISTING_URL="$HS/_matrix/client/unstable/com.freechat/rooms/$(urlenc "$GROUP")/existing_events"
EXISTING=$(curl -s -X POST "$EXISTING_URL" -H "Authorization: Bearer $CAROL" -H 'Content-Type: application/json' \
	-d "{\"event_ids\":[\"$M2\",\"$M3\",\"$A1\"]}" | j 'd["existing"]')
EXPECTED="['$A1']"
check "the existence check returns only messages that still exist" '[[ "$EXISTING" == "$EXPECTED" ]]'
check "non-members cannot ask" "[[ \$(curl -s -o /dev/null -w '%{http_code}' -X POST '$EXISTING_URL' -H 'Authorization: Bearer $DAVE' -H 'Content-Type: application/json' -d '{\"event_ids\":[]}') == 403 ]]"

echo "Creating a direct chat where bob turns it off..."
DM=$(api "$BOB" POST /createRoom "{\"preset\":\"trusted_private_chat\",\"is_direct\":true,\"invite\":[\"$(id dave)\"]}" | j 'd["room_id"]')
api "$DAVE" POST "/join/$(urlenc "$DM")" '{}' >/dev/null
api "$BOB" PUT "/user/$(urlenc "$(id bob)")/account_data/com.freechat.disappearing" "{\"read_ttl\":3,\"rooms\":{\"$DM\":0}}" >/dev/null
D1=$(send_text "$BOB" "$DM" dm-message)
receipt "$DAVE" "$DM" "$D1"
sleep 8
check "in a chat where it is turned off, reading deletes nothing" "! is_redacted '$DAVE' '$DM' '$D1'"

echo "Removing the per-chat setting (no entry in rooms = follow the global 3 seconds)..."
api "$BOB" PUT "/user/$(urlenc "$(id bob)")/account_data/com.freechat.disappearing" '{"read_ttl":3,"rooms":{}}' >/dev/null
D2=$(send_text "$BOB" "$DM" dm-follow-global)
receipt "$DAVE" "$DM" "$D2"
sleep 10
check "following the global setting, the message goes once the other side reads it" "is_redacted '$DAVE' '$DM' '$D2'"

echo "Direct chat permissions: both members are admins and may set room auto-delete..."
check "dave, the other member of the direct chat, can set room auto-delete too" "[[ \$(api_status '$DAVE' PUT '/rooms/$(urlenc "$DM")/state/com.freechat.disappearing/' '{\"ttl\":0}') == 200 ]]"

summary
