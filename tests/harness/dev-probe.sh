#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="${GAME_DIR:?set GAME_DIR}"
TIMEOUT="${TIMEOUT:-15}"
STAMP="$(date +%s)"

zig build dev-dll

mkdir -p "$GAME_DIR/hooks"
cp "$REPO_DIR/zig-out/dev/zil2cpp-dev.dll" "$GAME_DIR/hooks/dev-$STAMP.dll"

python3 "$REPO_DIR/scripts/probe.py" \
    --script "$REPO_DIR/tests/dev/probe.js" \
    --set "DLL_NAME=dev-$STAMP.dll" \
    --timeout "$TIMEOUT"
