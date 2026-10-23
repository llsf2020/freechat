#!/bin/bash
# Builds FreeChat for iOS on a Mac and runs the FreeChat unit tests, keeping all logs.
#
#   dev/build-ios.sh            set up → build → test
#   dev/build-ios.sh --no-setup skip the setup (fine from the second run on, and faster)
#
# Needs Xcode (from the App Store; open it once to accept the license) and Homebrew (https://brew.sh).
# Results go to dev/ios-logs/<time>/, and dev/ios-logs/latest points at the latest run:
#   summary.txt  whether each step passed, and where it failed (look here first when something goes wrong)
#   setup.log / build.log / test.log  full logs
#
# Without forks/element-x-ios, the upstream source listed in upstream.conf is downloaded and patches/element-x-ios applied.
# Must run on the bash 3.2 that ships with macOS: no newer syntax.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/forks/element-x-ios"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGS="$ROOT/dev/ios-logs/$STAMP"
SUMMARY="$LOGS/summary.txt"
SETUP=1
[ "${1:-}" = "--no-setup" ] && SETUP=0

mkdir -p "$LOGS"
ln -sfn "$STAMP" "$ROOT/dev/ios-logs/latest"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; echo "==> $*" >> "$SUMMARY"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*"; echo "error: $*" >> "$SUMMARY"; }

# Pulls the useful lines out of an xcodebuild log: compiler errors, lint errors, failed tests.
extract_errors() {
	grep -E "(error|fatal error): |\*\* (BUILD|TEST) FAILED \*\*|Test .*(failed|recorded an issue)|✘|Testing failed:|Command .* failed with" "$1" \
		| sed "s|$IOS/||g" | awk '!seen[$0]++' | head -200
}

run_step() { # run_step NAME LOGFILE COMMAND...
	local name="$1" log="$2"
	shift 2
	say "${name} (log: ${log#"$ROOT"/})"
	if "$@" > "$log" 2>&1; then
		say "$name: passed"
		return 0
	fi
	fail "$name: failed"
	{
		echo "---- $name: where it failed ----"
		extract_errors "$log"
		echo "---- $name: last 40 lines of the log ----"
		tail -40 "$log" | sed "s|$IOS/||g"
		echo
	} >> "$SUMMARY"
	return 1
}

{
	echo "FreeChat iOS build $STAMP"
	sw_vers 2>/dev/null
	xcodebuild -version 2>/dev/null
	swift --version 2>/dev/null | head -1
	echo
} > "$SUMMARY"

command -v xcodebuild >/dev/null || { fail "Xcode not found; install it from the App Store first"; exit 1; }
xcode-select -p | grep -qE "/Xcode[^/]*\.app/" || {
	fail "the command line tools do not point at Xcode; run: sudo xcode-select -s /Applications/Xcode.app"
	exit 1
}

if [ ! -d "$IOS" ]; then
	command -v git >/dev/null || { fail "git is missing"; exit 1; }
	run_step "download the upstream source and apply the patches" "$LOGS/checkout.log" sh "$ROOT/docker/checkout.sh" element-x-ios "$IOS" || exit 1
fi
(cd "$IOS" && echo "source version: $(git log --oneline -1)") >> "$SUMMARY"

# Name, bundle ID and icon from branding/ (see branding/README.md). Needs Pillow.
python3 -c "import PIL" 2>/dev/null || python3 -m pip install --user --quiet pillow >> "$LOGS/setup.log" 2>&1
run_step "apply branding (name, icon)" "$LOGS/branding.log" python3 "$ROOT/branding/apply.py" ios || exit 1

if [ "$SETUP" = 1 ]; then
	command -v brew >/dev/null || { fail "Homebrew is missing; install it from https://brew.sh first"; exit 1; }
	# Installs xcodegen, swiftgen, sourcery, swiftlint… and regenerates the Xcode project so new files are included.
	run_step "set up (a few minutes the first time)" "$LOGS/setup.log" bash -c "cd '$IOS' && swift run tools setup-project" || exit 1
fi

# The simulator build needs no signing and no Apple developer account. Only arm64: the simulator of an Apple
# silicon Mac, and the only slice dev/build-rust-sdk.sh builds.
run_step "build" "$LOGS/build.log" xcodebuild \
	-project "$IOS/ElementX.xcodeproj" -scheme ElementX \
	-destination "generic/platform=iOS Simulator" \
	-derivedDataPath "$IOS/build/DerivedData" \
	ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
BUILD_OK=$?

TEST_OK=1
if [ "$BUILD_OK" = 0 ]; then
	SIMULATOR="$(xcrun simctl list devices available | grep -E '^[[:space:]]+iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*$//')"
	if [ -z "$SIMULATOR" ]; then
		fail "no iPhone simulator available: download one in Xcode → Settings → Components"
	else
		echo "simulator: $SIMULATOR" >> "$SUMMARY"
		run_step "FreeChat unit tests" "$LOGS/test.log" xcodebuild \
			-project "$IOS/ElementX.xcodeproj" -scheme UnitTests \
			-destination "platform=iOS Simulator,name=$SIMULATOR" \
			-derivedDataPath "$IOS/build/DerivedData" \
			-only-testing:UnitTests/FreeChatTests \
			CODE_SIGNING_ALLOWED=NO test
		TEST_OK=$?
	fi
fi

echo
echo "summary: $SUMMARY"
if [ "$BUILD_OK" = 0 ] && [ "$TEST_OK" = 0 ]; then
	say "all passed"
else
	fail "some steps failed; see where in dev/ios-logs/latest/summary.txt"
	exit 1
fi
