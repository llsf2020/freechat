#!/usr/bin/env bash
# End-to-end test: metadata minimization
# Requires: dev/run.sh server running.
#
# - devices keep no IP address and no device name; "last seen" is kept to the day
# - renaming a device stores no name
# - expired messages are removed from the database outright, with no redaction; the room keeps working after its newest event goes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

DAY_MS=86400000

echo "Registering a user (signing in with a device name)..."
session=$(curl -s -X POST "$HS/_matrix/client/v3/register" -H 'Content-Type: application/json' \
	-d "{\"username\":\"meta$SUFFIX\",\"password\":\"pw-meta\"}" | j 'd.get("session", "")')
ALICE=$(curl -s -X POST "$HS/_matrix/client/v3/register" -H 'Content-Type: application/json' \
	-d "{\"username\":\"meta$SUFFIX\",\"password\":\"pw-meta\",\"initial_device_display_name\":\"Alice's Pixel 9\",\"auth\":{\"type\":\"m.login.registration_token\",\"token\":\"$TOKEN_REG\",\"session\":\"$session\"}}" \
	| j 'd["access_token"]')
BOB=$(register "metabob$SUFFIX")
send_text "$ALICE" "$(api "$ALICE" POST /createRoom '{"preset":"private_chat"}' | j 'd["room_id"]')" warm-up >/dev/null

DEV=$(api "$ALICE" GET /devices | j 'd["devices"][0]')
DEV_ID=$(echo "$DEV" | python3 -c "import sys, ast; print(ast.literal_eval(sys.stdin.read())['device_id'])")
dev_field() { api "$ALICE" GET "/devices/$(urlenc "$DEV_ID")" | j "d.get('$1')"; }

echo "Device info:"
check "no IP address is stored" "[[ \$(dev_field last_seen_ip) == None ]]"
check "the device name given at sign-in is not stored" "[[ \$(dev_field display_name) == None ]]"
check "last seen is kept to the day" "[[ \$(( \$(dev_field last_seen_ts) % $DAY_MS )) == 0 ]]"
api "$ALICE" PUT "/devices/$(urlenc "$DEV_ID")" '{"display_name":"My secret phone"}' >/dev/null
check "renaming the device stores no name either" "[[ \$(dev_field display_name) == None ]]"

echo "Expired messages are removed outright:"
ROOM=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"invite\":[\"@metabob$SUFFIX:localhost\"]}" | j 'd["room_id"]')
api "$BOB" POST "/join/$(urlenc "$ROOM")" '{}' >/dev/null
api "$ALICE" PUT "/rooms/$(urlenc "$ROOM")/state/com.freechat.disappearing/" '{"ttl":3}' >/dev/null
MSG=$(send_text "$ALICE" "$ROOM" "this should leave no trace")
sleep 10
check "the message is gone from the database after expiry" "[[ \$(api_status '$ALICE' GET '/rooms/$(urlenc "$ROOM")/event/$(urlenc "$MSG")') == 404 ]]"
check "the history has neither the message nor a redaction" "! api '$BOB' GET '/rooms/$(urlenc "$ROOM")/messages?dir=b&limit=100' | grep -qE '$MSG|m.room.redaction'"
check "it was the room's newest event, and the room keeps working without it" "[[ -n \$(send_text '$BOB' '$ROOM' still-works) ]]"
check "later messages can still be read" "[[ \$(api_status '$ALICE' GET '/rooms/$(urlenc "$ROOM")/messages?dir=b&limit=10') == 200 ]]"

summary
