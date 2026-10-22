#!/usr/bin/env bash
# FreeChat upstream tracking.
#
#   scripts/upstream.sh status            show baselines and whether upstream has a newer release
#   scripts/upstream.sh clone  <name>     clone forks/<name> and create the freechat branch at the baseline
#   scripts/upstream.sh export <name>     write our commits to patches/<name>/ (reviewable record)
#   scripts/upstream.sh sync   <name> <new-tag>
#                                         rebase our commits onto <new-tag>, keep a backup branch,
#                                         update upstream.conf and patches/ on success
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/upstream.conf"

die() { echo "error: $*" >&2; exit 1; }

# Prints "repo base branch status commit" for a component.
lookup() {
	awk -v n="$1" '$1 == n { print $2, $3, $4, $5, $6; found = 1 } END { exit !found }' "$CONF" \
		|| die "unknown component '$1' (see upstream.conf)"
}

latest_release() {
	local slug="${1#https://github.com/}"
	curl -fsS "https://api.github.com/repos/$slug/releases/latest" \
		| python3 -c 'import sys, json; print(json.load(sys.stdin).get("tag_name", "?"))' 2>/dev/null \
		|| echo "?"
}

cmd_status() {
	printf "%-18s %-18s %-18s %s\n" NAME BASELINE LATEST STATUS
	grep -vE '^\s*(#|$)' "$CONF" | while read -r name repo base _branch status _commit; do
		local latest mark=""
		latest="$(latest_release "$repo")"
		[[ "$latest" != "?" && "$latest" != "$base" ]] && mark="  <- newer release"
		printf "%-18s %-18s %-18s %s%s\n" "$name" "$base" "$latest" "$status" "$mark"
	done
}

cmd_clone() {
	local name="$1" repo base branch status commit
	read -r repo base branch status commit < <(lookup "$name")
	[[ "$branch" == "-" ]] && die "$name is unmodified; nothing to fork"
	local dir="$ROOT/forks/$name"
	[[ -d "$dir" ]] && die "$dir already exists"
	git clone --filter=blob:none --origin upstream "$repo" "$dir"
	git -C "$dir" checkout -b "$branch" "$base"
	[[ "$(git -C "$dir" rev-parse "$base^{commit}")" == "$commit" ]] \
		|| die "$base in $repo is not the commit upstream.conf records ($commit)"
}

cmd_export() {
	local name="$1" repo base branch status commit
	read -r repo base branch status commit < <(lookup "$name")
	local dir="$ROOT/forks/$name" out="$ROOT/patches/$name"
	[[ -d "$dir" ]] || die "$dir missing; run: $0 clone $name"
	rm -rf "$out"
	mkdir -p "$out"
	git -C "$dir" format-patch --quiet --no-signature -o "$out" "$base..$branch"
	echo "exported $(ls "$out" | wc -l) patch(es) to patches/$name/ (base $base)"
}

cmd_sync() {
	local name="$1" new="$2" repo base branch status commit
	read -r repo base branch status commit < <(lookup "$name")
	local dir="$ROOT/forks/$name"
	[[ -d "$dir" ]] || die "$dir missing; run: $0 clone $name"
	[[ -z "$(git -C "$dir" status --porcelain)" ]] || die "$dir has uncommitted changes"

	git -C "$dir" fetch upstream tag "$new" --no-tags
	local backup="$branch-$base"
	git -C "$dir" branch -f "$backup" "$branch"
	echo "backup of current work: branch $backup"

	git -C "$dir" checkout "$branch"
	if ! git -C "$dir" rebase --onto "$new" "$base" "$branch"; then
		cat >&2 <<-EOF

		rebase stopped on a conflict in forks/$name.
		  resolve the files, then: git -C forks/$name add <files> && git -C forks/$name rebase --continue
		  or give up:              git -C forks/$name rebase --abort
		when the rebase finishes, rerun: $0 sync $name $new
		EOF
		exit 1
	fi

	# Record the new baseline and its commit only after a clean rebase.
	local new_commit
	new_commit="$(git -C "$dir" rev-parse "$new^{commit}")"
	awk -v n="$name" -v t="$new" -v c="$new_commit" \
		'BEGIN { OFS = "  " } $1 == n && $0 !~ /^#/ { $3 = t; $6 = c } { print }' \
		"$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
	cmd_export "$name"
	echo "$name: $base -> $new ($new_commit). Now build and test."
}

case "${1:-}" in
	status) cmd_status ;;
	clone)  [[ $# -eq 2 ]] || die "usage: $0 clone <name>"; cmd_clone "$2" ;;
	export) [[ $# -eq 2 ]] || die "usage: $0 export <name>"; cmd_export "$2" ;;
	sync)   [[ $# -eq 3 ]] || die "usage: $0 sync <name> <new-tag>"; cmd_sync "$2" "$3" ;;
	*) sed -n '2,10p' "$0"; exit 1 ;;
esac
