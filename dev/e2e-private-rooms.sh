#!/usr/bin/env bash
# End-to-end test: private rooms (join with a password, ask to join) and screenshot blocking
# Requires: dev/run.sh server running.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

FC="$HS/_matrix/client/unstable/com.freechat"
fc() { # fc TOKEN METHOD PATH [JSON] -> body
	curl -s -X "$2" "$FC$3" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' ${4:+-d "$4"}
}
fc_status() { # fc_status TOKEN METHOD PATH [JSON] -> HTTP status
	curl -s -o /dev/null -w '%{http_code}' -X "$2" "$FC$3" -H "Authorization: Bearer $1" \
		-H 'Content-Type: application/json' ${4:+-d "$4"}
}
id() { echo "@$1$SUFFIX:localhost"; }

echo "Registering users..."
ALICE=$(register "alice$SUFFIX"); BOB=$(register "bob$SUFFIX"); CAROL=$(register "carol$SUFFIX")
DAVE=$(register "dave$SUFFIX"); ERIN=$(register "erin$SUFFIX"); FRANK=$(register "frank$SUFFIX")
GRACE=$(register "grace$SUFFIX"); HANK=$(register "hank$SUFFIX")

echo "alice creates a private room and invites bob (a regular member)..."
ROOM=$(api "$ALICE" POST /createRoom "{\"preset\":\"private_chat\",\"name\":\"top-secret-room\",\"invite\":[\"$(id bob)\"]}" | j 'd["room_id"]')
R=$(urlenc "$ROOM")
api "$BOB" POST "/join/$R" '{}' >/dev/null

echo "Outsiders cannot see the room:"
check "an outsider cannot read the room state" "[[ \$(api_status '$CAROL' GET '/rooms/$R/state') == 403 ]]"
check "an outsider cannot get the room summary (name, member count)" "[[ \$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $CAROL' '$HS/_matrix/client/v1/room_summary/$R') =~ ^(403|404)$ ]]"
check "an outsider joining directly is refused" "[[ \$(api_status '$CAROL' POST '/join/$R' '{}') == 403 ]]"
check "the room is not in the public directory" "! api '$CAROL' GET '/publicRooms' | grep -q '$ROOM'"

echo "Who may set the password:"
check "bob, a regular member, cannot set the password" "[[ \$(fc_status '$BOB' PUT '/rooms/$R/join_password' '{\"password\":\"bob-password\"}') == 403 ]]"
check "a too-short password is refused" "[[ \$(fc_status '$ALICE' PUT '/rooms/$R/join_password' '{\"password\":\"abc\"}') == 400 ]]"
check "alice, the admin, sets the password" "[[ \$(fc_status '$ALICE' PUT '/rooms/$R/join_password' '{\"password\":\"s3cret-pass\"}') == 200 ]]"
check "the admin can see that a password is set" "[[ \$(fc '$ALICE' GET '/rooms/$R/join_password' | j 'd[\"enabled\"]') == True ]]"
check "a regular member cannot tell whether there is a password" "[[ \$(fc_status '$BOB' GET '/rooms/$R/join_password') == 403 ]]"
check "callers must be signed in" "[[ \$(curl -s -o /dev/null -w '%{http_code}' '$FC/rooms/$R/join_password') =~ ^(400|401)$ ]]"

echo "Joining with the password:"
check "a wrong password is refused" "[[ \$(fc_status '$CAROL' POST '/rooms/$R/join_with_password' '{\"password\":\"wrong\"}') == 403 ]]"
check "a missing room answers the same as a wrong password" "[[ \$(fc_status '$CAROL' POST '/rooms/$(urlenc '!nope:localhost')/join_with_password' '{\"password\":\"wrong\"}') == 403 ]]"
for _ in 1 2 3 4; do fc_status "$CAROL" POST "/rooms/$R/join_with_password" '{"password":"wrong"}' >/dev/null; done
check "after 5 wrong attempts the user is locked out, even with the right password (429)" "[[ \$(fc_status '$CAROL' POST '/rooms/$R/join_with_password' '{\"password\":\"s3cret-pass\"}') == 429 ]]"
# Concurrent requests must not get past the limit (each one costs a slow argon2 check)
PAR=$(for _ in $(seq 1 12); do fc_status "$GRACE" POST "/rooms/$R/join_with_password" '{"password":"wrong"}' & done; wait)
check "of 12 concurrent wrong passwords at most 5 are checked, the rest get 429" "[[ \$(grep -o 429 <<<'$PAR' | wc -l) -ge 7 ]]"
for n in 1 2 3 4 5; do
	for _ in 1 2 3 4; do fc_status "$HANK" POST "/rooms/$(urlenc "!guess$n:localhost")/join_with_password" '{"password":"wrong"}' >/dev/null; done
done
check "one account is also locked out after 20 failures across rooms (429)" "[[ \$(fc_status '$HANK' POST '/rooms/$R/join_with_password' '{\"password\":\"s3cret-pass\"}') == 429 ]]"
check "dave gets invited with the right password" "[[ \$(fc_status '$DAVE' POST '/rooms/$R/join_with_password' '{\"password\":\"s3cret-pass\"}') == 200 ]]"
check "dave then joins normally" "[[ \$(api_status '$DAVE' POST '/join/$R' '{}') == 200 ]]"
check "the room state holds neither the password nor its hash" "! api '$DAVE' GET '/rooms/$R/state' | grep -qiE 's3cret|argon2'"

echo "After the password is removed it no longer works:"
check "the admin removes the password" "[[ \$(fc_status '$ALICE' PUT '/rooms/$R/join_password' '{}') == 200 ]]"
check "the old password no longer works" "[[ \$(fc_status '$FRANK' POST '/rooms/$R/join_with_password' '{\"password\":\"s3cret-pass\"}') == 403 ]]"

echo "Asking to join (knock):"
KROOM=$(api "$ALICE" POST /createRoom '{"preset":"private_chat","initial_state":[{"type":"m.room.join_rules","state_key":"","content":{"join_rule":"knock"}}]}' | j 'd["room_id"]')
K=$(urlenc "$KROOM")
check "erin asks to join" "[[ \$(api_status '$ERIN' POST '/knock/$K' '{\"reason\":\"hi\"}') == 200 ]]"
check "she cannot join before approval" "[[ \$(api_status '$ERIN' POST '/join/$K' '{}') == 403 ]]"
check "alice approves (invites)" "[[ \$(api_status '$ALICE' POST '/rooms/$K/invite' '{\"user_id\":\"$(id erin)\"}') == 200 ]]"
check "erin joins after approval" "[[ \$(api_status '$ERIN' POST '/join/$K' '{}') == 200 ]]"

echo "Screenshot blocking:"
check "a regular member cannot turn on screenshot blocking" "[[ \$(api_status '$BOB' PUT '/rooms/$R/state/com.freechat.privacy/' '{\"block_screenshots\":true}') == 403 ]]"
check "the admin turns on screenshot blocking" "[[ \$(api_status '$ALICE' PUT '/rooms/$R/state/com.freechat.privacy/' '{\"block_screenshots\":true}') == 200 ]]"
SS=$(curl -s -X POST "$HS/_matrix/client/unstable/org.matrix.simplified_msc3575/sync" \
	-H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
	-d '{"lists":{"all":{"ranges":[[0,20]],"required_state":[["m.room.name",""]],"timeline_limit":1}}}')
check "sliding sync returns the screenshot setting without being asked" "[[ \$(echo '$SS' | j '[e[\"content\"].get(\"block_screenshots\") for e in d[\"rooms\"][\"$ROOM\"][\"required_state\"] if e[\"type\"] == \"com.freechat.privacy\"]') == '[True]' ]]"

summary
