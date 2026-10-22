# Shared helpers for the end-to-end tests, sourced by dev/e2e-*.sh
# Requires: dev/run.sh server running.

HS="${HS:-http://localhost:8008}"
TOKEN_REG="freechat-dev"
SUFFIX="$(date +%s)$RANDOM"

pass=0 fail=0
check() { if eval "$2"; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1"; fail=$((fail + 1)); fi; }
j() { python3 -c "import sys, json; d = json.load(sys.stdin); print($1)"; }
urlenc() { python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

register() { # register NAME -> access token
	local user="$1" session
	session=$(curl -s -X POST "$HS/_matrix/client/v3/register" -H 'Content-Type: application/json' \
		-d "{\"username\":\"$user\",\"password\":\"pw-$user\"}" | j 'd.get("session", "")')
	curl -s -X POST "$HS/_matrix/client/v3/register" -H 'Content-Type: application/json' \
		-d "{\"username\":\"$user\",\"password\":\"pw-$user\",\"auth\":{\"type\":\"m.login.registration_token\",\"token\":\"$TOKEN_REG\",\"session\":\"$session\"}}" \
		| j 'd["access_token"]'
}

api() { # api TOKEN METHOD PATH [JSON]
	curl -s -X "$2" "$HS/_matrix/client/v3$3" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' ${4:+-d "$4"}
}

api_status() { # api_status TOKEN METHOD PATH [JSON] -> HTTP status code
	curl -s -o /dev/null -w '%{http_code}' -X "$2" "$HS/_matrix/client/v3$3" \
		-H "Authorization: Bearer $1" -H 'Content-Type: application/json' ${4:+-d "$4"}
}

txn() { echo "t$RANDOM$RANDOM"; }

send_text() { # send_text TOKEN ROOM_ID BODY -> event id
	api "$1" PUT "/rooms/$(urlenc "$2")/send/m.room.message/$(txn)" "{\"msgtype\":\"m.text\",\"body\":\"$3\"}" | j 'd["event_id"]'
}

event_json() { # event_json TOKEN ROOM_ID EVENT_ID
	api "$1" GET "/rooms/$(urlenc "$2")/event/$(urlenc "$3")"
}

is_redacted() { # is_redacted TOKEN ROOM_ID EVENT_ID -> exit 0 when the message is gone (purged or emptied)
	local status
	status=$(api_status "$1" GET "/rooms/$(urlenc "$2")/event/$(urlenc "$3")")
	[[ $status == 404 ]] || [[ $(event_json "$1" "$2" "$3" | j 'len(d.get("content", {"x": 1}))') == 0 ]]
}

summary() {
	echo
	echo "passed $pass, failed $fail"
	[[ $fail -eq 0 ]]
}
