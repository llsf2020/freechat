#!/bin/sh
# Checks out an upstream component at its FreeChat baseline and applies our patches.
#
#   docker/checkout.sh <name> <dest>
#
# The baseline, its commit and the repository come from upstream.conf; the
# patches from patches/<name>/. Used by the Dockerfiles and CI, so a build
# always matches what upstream.conf records. The clone must land on the
# recorded commit: a tag that was moved upstream fails the build. The baseline
# can also be a bare commit hash.
set -eu

name="$1"
dest="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"

line="$(awk -v n="$name" '$1 == n && $0 !~ /^#/ { print $2, $3, $6 }' "$root/upstream.conf")"
[ -n "$line" ] || { echo "unknown component: $name" >&2; exit 1; }
read -r repo ref commit <<EOF
$line
EOF
[ ${#commit} -eq 40 ] || { echo "$name: no baseline commit in upstream.conf" >&2; exit 1; }

if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
	# The baseline is a commit with no tag (e.g. the matrix-rust-sdk commit a binding release was built from).
	git init --quiet "$dest"
	git -C "$dest" fetch --quiet --depth 1 "$repo" "$ref"
	git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
else
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$repo" "$dest"
fi
actual="$(git -C "$dest" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
	echo "$name: $ref is $actual upstream, but upstream.conf records $commit" >&2
	exit 1
fi
if [ -d "$root/patches/$name" ] && ls "$root/patches/$name"/*.patch >/dev/null 2>&1; then
	git -C "$dest" -c user.name=freechat -c user.email=freechat@localhost \
		am --quiet --3way "$root/patches/$name"/*.patch
fi
echo "$name: $ref + $(find "$root/patches/$name" -name "*.patch" 2>/dev/null | wc -l) patch(es)"
