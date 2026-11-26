#!/usr/bin/env bash
# Wait for a file to exist.
set -euo pipefail
PATH_NAME=""
TIMEOUT=60
INTERVAL=0.25
while [ $# -gt 0 ]; do
    case "$1" in
        --path) PATH_NAME="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *) echo "wait-file: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$PATH_NAME" ]; then
    echo "usage: wait-file.sh --path FILE [--timeout SECONDS]" >&2
    exit 2
fi
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$PATH_NAME" ]; then
        echo "$PATH_NAME"
        exit 0
    fi
    sleep "$INTERVAL"
done
echo "wait-file: timed out waiting for $PATH_NAME" >&2
exit 1
