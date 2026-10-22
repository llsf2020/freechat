#!/usr/bin/env bash
# FreeChat local test environment
#
#   dev/run.sh build    build Tuwunel (debug)
#   dev/run.sh server   start Tuwunel                 http://localhost:8008
#   dev/run.sh web      start the Element Web dev server  http://localhost:8080
#   dev/run.sh reset    delete the local test database
#
# Test accounts register with the registration token: freechat-dev
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUWUNEL="$ROOT/forks/tuwunel"
WEB="$ROOT/forks/element-web"

# Tools that are not on PATH: put their location in dev/local.env (not committed), e.g. export PATH="/opt/node/bin:$PATH"
[[ -f "$ROOT/dev/local.env" ]] && source "$ROOT/dev/local.env"

case "${1:-}" in
	build)
		cd "$TUWUNEL" && cargo build --bin tuwunel
		;;
	server)
		mkdir -p "$ROOT/dev/data/tuwunel"
		# In restricted environments (containers, sandboxes) jemalloc may not get a definite CPU count and exits
		export MALLOC_CONF="${MALLOC_CONF:-percpu_arena:disabled}"
		cd "$ROOT" && exec "$TUWUNEL/target/debug/tuwunel" -c dev/tuwunel.toml
		;;
	web)
		cp "$ROOT/dev/element-config.json" "$WEB/apps/web/config.json"
		# `pnpm start` also starts the shared packages in watch mode, whose upstream type check fails (`events` has no linked type declarations).
		# The shared packages built by `pnpm install` are enough, so only the web app's dev server is started here.
		cd "$WEB/apps/web" && exec pnpm exec webpack-dev-server --output-path webapp \
			--output-filename='bundles/_dev_/[name].js' --output-chunk-filename='bundles/_dev_/[name].js' --mode development
		;;
	reset)
		rm -rf "$ROOT/dev/data/tuwunel"
		echo "Local test data deleted"
		;;
	*)
		sed -n '2,10p' "$0"
		exit 1
		;;
esac
