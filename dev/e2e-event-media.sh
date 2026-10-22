#!/usr/bin/env bash
# End-to-end test: clients report the attachments of encrypted messages, which are deleted when the message expires
# Requires: dev/run.sh server running.
#
# Android and iOS encrypt attachments inside the Rust SDK and cannot list the file IDs in plaintext,
# so after sending they report them to com.freechat/rooms/{roomId}/event_media.
#
# 1. alice and bob share a room with auto-delete (10 seconds); alice uploads M1 and sends an encrypted message
# 2. Check that:
#    - bob cannot report for alice's message (404)
#    - when alice reports M1, bob's file M2, a remote and an invalid address, only M1 is kept
#    - messages in rooms without auto-delete record nothing (M3)
#    - reporting more than 64 files at once is refused (400)
# 3. After 20 seconds: the message is gone, M1 is deleted, M2 and M3 remain
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

upload() { # upload TOKEN -> mxc
	curl -s -X POST "$HS/_matrix/media/v3/upload?filename=x.bin" -H "Authorization: Bearer $1" \
		-H 'Content-Type: application/octet-stream' --data-binary 'encrypted-bytes' | j 'd["content_uri"]'
}
media_status() { # media_status TOKEN MXC -> HTTP status code
	curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "$HS/_matrix/client/v1/media/download/${2#mxc://}"
}
send_encrypted() { # send_encrypted TOKEN ROOM_ID -> event id
	api "$1" PUT "/rooms/$(urlenc "$2")/send/m.room.encrypted/$(txn)" \
		'{"algorithm":"m.megolm.v1.aes-sha2","ciphertext":"AAAA","session_id":"s"}' | j 'd["event_id"]'
}
report() { # report TOKEN ROOM_ID JSON -> response body
	curl -s -X POST "$HS/_matrix/client/unstable/com.freechat/rooms/$(urlenc "$2")/event_media" \
		-H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"
}
report_status() { # report_status TOKEN ROOM_ID JSON -> HTTP status code
	curl -s -o /dev/null -w '%{http_code}' -X POST "$HS/_matrix/client/unstable/com.freechat/rooms/$(urlenc "$2")/event_media" \
		-H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"
}

echo "Registering users..."
ALICE=$(register "alice$SUFFIX")
BOB=$(register "bob$SUFFIX")
BOB_ID="@bob$SUFFIX:localhost"

ROOM=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"invite\":[\"$BOB_ID\"]}" | j 'd["room_id"]')
api "$BOB" POST "/join/$(urlenc "$ROOM")" '{}' >/dev/null
api "$ALICE" PUT "/rooms/$(urlenc "$ROOM")/state/com.freechat.disappearing/" '{"ttl":10}' >/dev/null
PLAIN=$(api "$ALICE" POST /createRoom '{"preset":"private_chat"}' | j 'd["room_id"]')

M1=$(upload "$ALICE")
M2=$(upload "$BOB")
M3=$(upload "$ALICE")
EV=$(send_encrypted "$ALICE" "$ROOM")
EV_PLAIN=$(send_encrypted "$ALICE" "$PLAIN")

echo "Reporting..."
check "bob cannot report for alice's message (404)" \
	"[[ \$(report_status '$BOB' '$ROOM' '{\"event_id\":\"$EV\",\"mxcs\":[\"$M2\"]}') == 404 ]]"
check "only local files alice uploaded herself are kept" \
	"[[ \$(report '$ALICE' '$ROOM' '{\"event_id\":\"$EV\",\"mxcs\":[\"$M1\",\"$M2\",\"mxc://elsewhere.example/x\",\"https://x\"]}' | j 'd[\"kept\"]') == 1 ]]"
check "the wrong room answers not found (404)" \
	"[[ \$(report_status '$ALICE' '$PLAIN' '{\"event_id\":\"$EV\",\"mxcs\":[\"$M1\"]}') == 404 ]]"
check "messages that never expire record nothing" \
	"[[ \$(report '$ALICE' '$PLAIN' '{\"event_id\":\"$EV_PLAIN\",\"mxcs\":[\"$M3\"]}' | j 'd[\"kept\"]') == 0 ]]"
MANY=$(python3 -c "import json; print(json.dumps(['$M1'] * 65))")
check "more than 64 files in one report are refused (400)" \
	"[[ \$(report_status '$ALICE' '$ROOM' '{\"event_id\":\"$EV\",\"mxcs\":$MANY}') == 400 ]]"

echo "Waiting 20 seconds..."
sleep 20

echo "Results:"
check "the encrypted message is gone after expiry" "[[ \$(api_status '$ALICE' GET '/rooms/$(urlenc "$ROOM")/event/$(urlenc "$EV")') == 404 ]]"
check "the reported attachment M1 is deleted from the server" "[[ \$(media_status '$ALICE' '$M1') == 404 ]]"
check "bob's file M2 is not deleted" "[[ \$(media_status '$BOB' '$M2') == 200 ]]"
check "file M3 of a message that never expires is not deleted" "[[ \$(media_status '$ALICE' '$M3') == 200 ]]"

summary
