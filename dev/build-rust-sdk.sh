#!/usr/bin/env bash
# Builds FreeChat's Rust SDK (matrix-rust-sdk at its upstream.conf baseline plus patches/matrix-rust-sdk) and
# points an app at it.
#
#   dev/build-rust-sdk.sh android [AAR]
#                                   build for Android (arm64) into AAR, by default
#                                   forks/element-x-android/libraries/rustsdk/matrix-rust-sdk.aar, which debug
#                                   builds of the Android app use instead of the published SDK
#   dev/build-rust-sdk.sh ios       build for the iOS simulator (Apple silicon) into forks/matrix-rust-sdk,
#                                   and point forks/element-x-ios/project.yml at it (on a Mac)
#   dev/build-rust-sdk.sh ios-point only point project.yml at an SDK already built there (e.g. from a CI cache)
#
# Forks that are missing are checked out with docker/checkout.sh. Android needs the Android NDK
# (ANDROID_NDK_HOME), cargo-ndk, Java 17 and the aarch64-linux-android Rust target; iOS needs Xcode and the
# aarch64-apple-ios-sim Rust target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Tools that are not on PATH: put their location in dev/local.env (not committed).
# shellcheck disable=SC1091
[[ -f "$ROOT/dev/local.env" ]] && source "$ROOT/dev/local.env"

SDK="$ROOT/forks/matrix-rust-sdk"
IOS="$ROOT/forks/element-x-ios"
[[ -d "$SDK" || ${1:-} == ios-point ]] || sh "$ROOT/docker/checkout.sh" matrix-rust-sdk "$SDK"

# The app's MatrixRustSDK package becomes the local one (the path is relative to project.yml).
point_ios_project() {
	[[ -f "$SDK/Package.swift" && -d "$SDK/bindings/apple/generated/MatrixSDKFFI.xcframework" ]] \
		|| { echo "no Rust SDK built for iOS in forks/matrix-rust-sdk" >&2; exit 1; }
	python3 - "$IOS/project.yml" <<-'PY'
		import re, sys
		path = sys.argv[1]
		text = open(path, encoding="utf-8").read()
		new, n = re.subn(r"(\n  MatrixRustSDK:\n)    url: [^\n]+\n    exactVersion: [^\n]+\n", r"\1    path: ../matrix-rust-sdk\n", text)
		if n != 1 and "path: ../matrix-rust-sdk" not in text:
		    sys.exit("could not find the MatrixRustSDK package in project.yml")
		open(path, "w", encoding="utf-8").write(new)
	PY
	echo "forks/element-x-ios now uses the Rust SDK in forks/matrix-rust-sdk"
}

case "${1:-}" in
	android)
		: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
		aar="$(realpath -m "${2:-$ROOT/forks/element-x-android/libraries/rustsdk/matrix-rust-sdk.aar}")"
		[[ -d "$(dirname "$aar")" ]] || { echo "$(dirname "$aar") does not exist" >&2; exit 1; }
		KOTLIN="$ROOT/forks/matrix-rust-components-kotlin"
		[[ -d "$KOTLIN" ]] || sh "$ROOT/docker/checkout.sh" matrix-rust-components-kotlin "$KOTLIN"
		# Only arm64: what phones run. The other ABIs would each add a long build.
		"$KOTLIN/scripts/build.sh" -p "$SDK" -m sdk -t aarch64-linux-android -o "$aar"
		;;
	ios)
		[[ -f "$IOS/project.yml" ]] || { echo "forks/element-x-ios is missing" >&2; exit 1; }
		# Writes bindings/apple/generated/ and a Package.swift at the root of the SDK checkout.
		(cd "$SDK" && cargo xtask swift build-framework --target aarch64-apple-ios-sim)
		point_ios_project
		;;
	ios-point)
		[[ -f "$IOS/project.yml" ]] || { echo "forks/element-x-ios is missing" >&2; exit 1; }
		point_ios_project
		;;
	*)
		sed -n '2,15p' "$0"
		exit 1
		;;
esac
