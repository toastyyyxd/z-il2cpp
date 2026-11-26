#!/usr/bin/env bash
# Install one or more APKs with adb.
set -euo pipefail
if [ $# -eq 0 ]; then
    echo "usage: android-install.sh APK..." >&2
    exit 2
fi
command -v adb >/dev/null 2>&1 || { echo "android-install: missing adb" >&2; exit 1; }
if [ $# -eq 1 ]; then
    adb install -r "$1" >/dev/null
else
    adb install-multiple -r "$@" >/dev/null
fi
