#!/usr/bin/env bash
# Builds FreeChat's Rust SDK (matrix-rust-sdk at its upstream.conf baseline plus patches/matrix-rust-sdk) and
# points an app at it.
#
#   dev/build-rust-sdk.sh android [AAR]
#                                   build for Android (arm64) into AAR, by default
#                                   forks/element-x-android/libraries/rustsdk/matrix-rust-sdk.aar, which the
#                                   Android app builds use instead of the published SDK
#   dev/build-rust-sdk.sh android-target TARGET
#                                   release build for one Android target (e.g. armv7-linux-androideabi) into
#                                   forks/matrix-rust-components-kotlin/sdk/sdk-android/src/main: the library
#                                   under jniLibs/<ABI>/, the Kotlin bindings under kotlin/
#   dev/build-rust-sdk.sh android-aar [AAR]
#                                   package what android-target built (one or more targets) into a release
#                                   AAR, by default the path of the android command
#   dev/build-rust-sdk.sh ios       build for the iOS simulator (Apple silicon) into the Swift package
#                                   forks/matrix-rust-components-swift, and point forks/element-x-ios/project.yml
#                                   at it (on a Mac)
#   dev/build-rust-sdk.sh ios-point only point project.yml at a package already built there (e.g. from a CI cache)
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
# Named like upstream's binary package: Swift packages are known by their directory name, and the app's other
# packages ask for matrix-rust-components-swift.
SWIFT_PKG="$ROOT/forks/matrix-rust-components-swift"
[[ -d "$SDK" || ${1:-} == ios-point || ${1:-} == android-aar ]] || sh "$ROOT/docker/checkout.sh" matrix-rust-sdk "$SDK"

# The app's MatrixRustSDK package becomes the local one (the path is relative to project.yml).
point_ios_project() {
	[[ -f "$SWIFT_PKG/Package.swift" && -d "$SWIFT_PKG/MatrixSDKFFI.xcframework" ]] \
		|| { echo "no Rust SDK built for iOS in forks/matrix-rust-components-swift" >&2; exit 1; }
	python3 - "$IOS/project.yml" <<-'PY'
		import re, sys
		path = sys.argv[1]
		text = open(path, encoding="utf-8").read()
		new, n = re.subn(r"(\n  MatrixRustSDK:\n)    url: [^\n]+\n    exactVersion: [^\n]+\n", r"\1    path: ../matrix-rust-components-swift\n", text)
		if n != 1 and "path: ../matrix-rust-components-swift" not in text:
		    sys.exit("could not find the MatrixRustSDK package in project.yml")
		open(path, "w", encoding="utf-8").write(new)
	PY
	echo "forks/element-x-ios now uses the Rust SDK in forks/matrix-rust-components-swift"
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
	android-target)
		: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
		[[ -n "${2:-}" ]] || { echo "which target?" >&2; exit 1; }
		KOTLIN="$ROOT/forks/matrix-rust-components-kotlin"
		[[ -d "$KOTLIN" ]] || sh "$ROOT/docker/checkout.sh" matrix-rust-components-kotlin "$KOTLIN"
		bash "$KOTLIN/scripts/build-rust-for-target.sh" -p "$SDK" -m sdk -t "$2" -r
		;;
	android-aar)
		aar="$(realpath -m "${2:-$ROOT/forks/element-x-android/libraries/rustsdk/matrix-rust-sdk.aar}")"
		[[ -d "$(dirname "$aar")" ]] || { echo "$(dirname "$aar") does not exist" >&2; exit 1; }
		KOTLIN="$ROOT/forks/matrix-rust-components-kotlin"
		src="$KOTLIN/sdk/sdk-android/src/main"
		compgen -G "$src/jniLibs/*/libmatrix_sdk_ffi.so" > /dev/null \
			|| { echo "nothing built for Android in $src: run android-target first" >&2; exit 1; }
		# The checkout carries upstream's bindings; ours have the FreeChat additions.
		grep -q "fun eraseEventsLocally" "$src/kotlin/org/matrix/rustcomponents/sdk/matrix_sdk_ffi.kt" \
			|| { echo "the Kotlin bindings in $src are not FreeChat's" >&2; exit 1; }
		ls "$src"/jniLibs/
		(cd "$KOTLIN" && bash scripts/build-aar.sh -r -m sdk -o "$aar")
		;;
	ios)
		[[ -f "$IOS/project.yml" ]] || { echo "forks/element-x-ios is missing" >&2; exit 1; }
		# Copies the xcframework and the Swift sources into the package; its manifest is the SDK's own one for
		# local development, with the paths of that layout.
		mkdir -p "$SWIFT_PKG"
		(cd "$SDK" && cargo xtask swift build-framework --target aarch64-apple-ios-sim --components-path "$SWIFT_PKG")
		sed -e 's|path: "bindings/apple/generated/MatrixSDKFFI.xcframework"|path: "MatrixSDKFFI.xcframework"|' \
			-e 's|path: "bindings/apple/generated/swift"|path: "Sources/MatrixRustSDK"|' \
			"$SDK/bindings/apple/Debug-Package.swift" > "$SWIFT_PKG/Package.swift"
		grep -q '"Sources/MatrixRustSDK"' "$SWIFT_PKG/Package.swift" \
			|| { echo "bindings/apple/Debug-Package.swift changed upstream" >&2; exit 1; }
		point_ios_project
		;;
	ios-point)
		[[ -f "$IOS/project.yml" ]] || { echo "forks/element-x-ios is missing" >&2; exit 1; }
		point_ios_project
		;;
	*)
		sed -n '2,22p' "$0"
		exit 1
		;;
esac
