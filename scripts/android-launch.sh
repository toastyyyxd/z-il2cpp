#!/usr/bin/env bash
# Force-stop, clear logcat, and start an Android package.
set -euo pipefail
PACKAGE=""
ACTIVITY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --package) PACKAGE="$2"; shift 2 ;;
        --activity) ACTIVITY="$2"; shift 2 ;;
        *) echo "android-launch: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$PACKAGE" ]; then
    echo "usage: android-launch.sh --package NAME [--activity NAME]" >&2
    exit 2
fi
command -v adb >/dev/null 2>&1 || { echo "android-launch: missing adb" >&2; exit 1; }
adb shell am force-stop "$PACKAGE"
adb logcat -c
if [ -n "$ACTIVITY" ]; then
    adb shell am start -n "$PACKAGE/$ACTIVITY" >/dev/null
else
    adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null
fi
