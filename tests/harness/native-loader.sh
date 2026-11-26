#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_DIR/zig-out/native"
GAME_DIR="${GAME_DIR:?set GAME_DIR}"
GAME_EXE="${GAME_EXE:-game.exe}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
TIMEOUT="${TIMEOUT:-60}"

restore() {
    if [ -f "$GAME_DIR/winhttp.autoload.bak" ]; then
        cp "$GAME_DIR/winhttp.autoload.bak" "$GAME_DIR/winhttp.dll"
    fi
    rm -f "$GAME_DIR/zil2cpp.dll"
    "$REPO_DIR/scripts/wine-stop.sh" --prefix "$WINEPREFIX"
}
trap restore EXIT

zig build native-proxy native-dll

if [ ! -f "$GAME_DIR/winhttp_orig.dll" ]; then
    echo "native: winhttp_orig.dll missing in game directory" >&2
    exit 1
fi
if [ ! -f "$GAME_DIR/winhttp.autoload.bak" ]; then
    cp "$GAME_DIR/winhttp.dll" "$GAME_DIR/winhttp.autoload.bak"
fi

"$REPO_DIR/scripts/windows-deploy.sh" \
    --game-dir "$GAME_DIR" \
    --copy "$OUT/winhttp.dll:winhttp.dll" \
    --copy "$OUT/zil2cpp.dll:zil2cpp.dll"

rm -f "$GAME_DIR/zil2cpp-native-result.json" "$GAME_DIR/zil2cpp-stage.txt" "$OUT/run.log"
"$REPO_DIR/scripts/wine-run.sh" \
    --game-dir "$GAME_DIR" --exe "$GAME_EXE" --prefix "$WINEPREFIX" \
    --log "$OUT/run.log" --background --batchmode --dll-override "winhttp=n,b" >/dev/null

"$REPO_DIR/scripts/wait-file.sh" --path "$GAME_DIR/zil2cpp-native-result.json" --timeout "$TIMEOUT"
"$REPO_DIR/scripts/wine-stop.sh" --prefix "$WINEPREFIX"

echo "native: stage $(cat "$GAME_DIR/zil2cpp-stage.txt" 2>/dev/null || echo none)"
cat "$GAME_DIR/zil2cpp-native-result.json"
grep -q '"ok": true' "$GAME_DIR/zil2cpp-native-result.json" || { echo "native: FAIL" >&2; exit 1; }
echo "native: PASS"
