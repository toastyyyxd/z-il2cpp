#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

cp "$OUT/winhttp.dll" "$GAME_DIR/winhttp.dll"
cp "$OUT/zil2cpp.dll" "$GAME_DIR/zil2cpp.dll"

rm -f "$GAME_DIR/zil2cpp-native-result.json" "$GAME_DIR/zil2cpp-stage.txt" "$OUT/run.log"

(
    cd "$GAME_DIR"
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="winhttp=n,b" \
        timeout "$TIMEOUT" wine "$GAME_EXE" -batchmode -nographics -logFile - > "$OUT/run.log" 2>&1
) &
game_pid=$!

for _ in $(seq 1 "$TIMEOUT"); do
    if [ -f "$GAME_DIR/zil2cpp-native-result.json" ]; then
        break
    fi
    sleep 1
done

WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
wait "$game_pid" 2>/dev/null || true

echo "native: stage $(cat "$GAME_DIR/zil2cpp-stage.txt" 2>/dev/null || echo none)"
if [ ! -f "$GAME_DIR/zil2cpp-native-result.json" ]; then
    echo "native: no result" >&2
    tail -10 "$OUT/run.log" >&2 || true
    exit 1
fi

cat "$GAME_DIR/zil2cpp-native-result.json"
grep -q '"ok": true' "$GAME_DIR/zil2cpp-native-result.json" || { echo "native: FAIL" >&2; exit 1; }
echo "native: PASS"
