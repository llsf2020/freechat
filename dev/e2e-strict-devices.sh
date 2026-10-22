#!/usr/bin/env bash
# End-to-end test: strict-mode devices (device ID FCS<minutes>_<random>) are deleted by the server once idle
#
# Start the local server first (dev/run.sh server). The test takes about 2.5 minutes.
#   - an idle strict device (1 minute): after the timeout its token stops working and the device is gone
#   - a strict device in constant use (1 minute): kept
#   - a regular device: unaffected
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/dev/e2e-lib.sh"

login_device() { # login_device USER DEVICE_ID -> access token
	curl -s -X POST "$HS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
		-d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$1\"},\"password\":\"pw-$1\",\"device_id\":\"$2\"}" \
		| j 'd["access_token"]'
}
devices() { api "$1" GET /devices | j '",".join(sorted(x["device_id"] for x in d["devices"]))'; }

echo "Registering and signing in three devices..."
U="strictdev$SUFFIX"
NORMAL=$(register "$U")
IDLE=$(login_device "$U" "FCS1_idle$SUFFIX")
ACTIVE=$(login_device "$U" "FCS1_active$SUFFIX")
check "both strict devices signed in" "[[ -n '$IDLE' && -n '$ACTIVE' ]]"
check "the server has three devices" "[[ \$(devices '$NORMAL' | tr ',' '\n' | wc -l) == 3 ]]"

echo "Waiting 130 seconds (1 minute idle + 1 minute grace + the check interval), using ACTIVE all along..."
for _ in $(seq 1 13); do
	api "$ACTIVE" GET /account/whoami >/dev/null
	sleep 10
done

check "the idle strict device's token no longer works" "[[ \$(api_status '$IDLE' GET /account/whoami) == 401 ]]"
check "the idle strict device is deleted" "[[ \$(devices '$NORMAL') != *FCS1_idle* ]]"
check "the strict device in use is still there" "[[ \$(api_status '$ACTIVE' GET /account/whoami) == 200 ]]"
check "the regular device is unaffected" "[[ \$(api_status '$NORMAL' GET /account/whoami) == 200 ]]"

summary
