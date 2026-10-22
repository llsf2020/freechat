#!/usr/bin/env bash
# End-to-end test: deleted messages leave the database files (not just a "deleted" marker)
#
# The script restarts the local server itself with FREECHAT_SCRUB_INTERVAL_SECS=10; stop dev/run.sh server first.
#   1. Send a plaintext message with a unique mark and confirm the database files contain it (control)
#   2. After the message expires, wait for the background compaction
#   3. No file in the database directory contains the mark
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/dev/e2e-lib.sh"
DB="$ROOT/dev/data/tuwunel"

SERVER_PID=""
stop_server() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
	for _ in $(seq 1 30); do pgrep -x tuwunel >/dev/null || return 0; sleep 1; done
}
trap stop_server EXIT
pgrep -x tuwunel >/dev/null && { echo "stop the running server first" >&2; exit 1; }

FREECHAT_SCRUB_INTERVAL_SECS=10 "$ROOT/dev/run.sh" server >"$ROOT/dev/server-scrub.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -sf "$HS/_matrix/client/versions" >/dev/null && break; sleep 1; done

ALICE=$(register "scrub$SUFFIX")
ROOM=$(api "$ALICE" POST /createRoom '{"preset":"private_chat"}' | j 'd["room_id"]')
api "$ALICE" PUT "/rooms/$(urlenc "$ROOM")/state/com.freechat.disappearing/" '{"ttl":5}' >/dev/null
MARK="scrubmark${SUFFIX}xyz"
send_text "$ALICE" "$ROOM" "$MARK" >/dev/null
sleep 1

found() { grep -rqa "$MARK" "$DB"; }
check "before deletion: the database files contain the message (control)" "found"

echo "Waiting for expiry and the background compaction (about 30 seconds, up to 3 minutes on slow machines)..."
for _ in $(seq 1 180); do
	grep -q "Scrubbed deleted messages" "$ROOT/dev/server-scrub.log" && break
	sleep 1
done
check "the background compaction ran" "grep -q 'Scrubbed deleted messages' '$ROOT/dev/server-scrub.log'"
check "after deletion: no file in the database directory contains the message" "! found"

summary
