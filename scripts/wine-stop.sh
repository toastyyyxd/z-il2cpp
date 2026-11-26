#!/usr/bin/env bash
# Stop the Wine server for a prefix.
set -euo pipefail
PREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "wine-stop: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if command -v wineserver >/dev/null 2>&1; then
    WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
fi
