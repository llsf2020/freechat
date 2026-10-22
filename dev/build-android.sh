#!/usr/bin/env bash
# Builds Element X (FreeChat for Android) on machines with limited memory
#
#   dev/build-android.sh                 build the F-Droid debug APK (no Google services)
#   dev/build-android.sh <gradle tasks…> run any Gradle tasks
#
# Gradle runs in a systemd scope capped at 5 GB of memory: going over kills only the build,
# not the whole machine. See also the memory settings in ~/.gradle/gradle.properties.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# When JDK 21 is not the system's default Java, set JAVA_HOME in dev/local.env (not committed)
[[ -f "$ROOT/dev/local.env" ]] && source "$ROOT/dev/local.env"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

TASKS=("$@")
[[ ${#TASKS[@]} -eq 0 ]] && TASKS=(:app:assembleFdroidDebug)

# Name, package name and icon from branding/ (see branding/README.md).
python3 "$ROOT/branding/apply.py" android

cd "$ROOT/forks/element-x-android"
# CI machines have no systemd user session (and enough memory): run Gradle directly there.
if systemd-run --user --scope --quiet true 2>/dev/null; then
	exec systemd-run --user --scope --quiet -p MemoryMax=5G -p MemorySwapMax=2G \
		./gradlew --no-daemon --console=plain "${TASKS[@]}"
fi
exec ./gradlew --no-daemon --console=plain "${TASKS[@]}"
