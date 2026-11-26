#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_DIR/zig-out/hooks"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"

command -v wine >/dev/null 2>&1 || { echo "hooks: wine not found" >&2; exit 1; }

zig build hooks-host

rm -f "$OUT/hooks-result.json"
(
    cd "$OUT"
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all timeout 60 wine hooks-host.exe >/dev/null 2>&1 || true
)

if [ ! -f "$OUT/hooks-result.json" ]; then
    echo "hooks: no hooks-result.json" >&2
    exit 1
fi

cat "$OUT/hooks-result.json"
grep -q '"ok": true' "$OUT/hooks-result.json" || { echo "hooks: FAIL" >&2; exit 1; }
echo "hooks: PASS"
