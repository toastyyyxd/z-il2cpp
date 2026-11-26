#!/usr/bin/env bash
# Read a file from an application's private data directory.
set -euo pipefail
PACKAGE=""
PATH_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --package) PACKAGE="$2"; shift 2 ;;
        --path) PATH_NAME="$2"; shift 2 ;;
        *) echo "android-read-log: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$PACKAGE" ] || [ -z "$PATH_NAME" ]; then
    echo "usage: android-read-log.sh --package NAME --path FILE" >&2
    exit 2
fi
command -v adb >/dev/null 2>&1 || { echo "android-read-log: missing adb" >&2; exit 1; }
adb shell run-as "$PACKAGE" cat "$PATH_NAME"
