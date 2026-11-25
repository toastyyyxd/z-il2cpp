#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="${GAME_DIR:?set GAME_DIR to a game directory with the winhttp proxy deployed}"
FRIDA_GADGET="${FRIDA_GADGET:?set FRIDA_GADGET to a windows gadget dll, version 17.25 or newer}"
GAME_EXE="${GAME_EXE:-game.exe}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
TIMEOUT="${TIMEOUT:-120}"
OUT="$REPO_DIR/zig-out/ingame"

if [ ! -x "$(command -v wine)" ]; then
    echo "ingame: wine not found" >&2
    exit 1
fi

mkdir -p "$OUT"
zig build hot

rm -rf "$GAME_DIR/hot"
mkdir -p "$GAME_DIR/hot" "$GAME_DIR/mods"
cp "$REPO_DIR"/zig-out/hot/* "$GAME_DIR/hot/"
cp "$REPO_DIR/tests/ingame/agent.js" "$GAME_DIR/mods/ingame.js"
cp "$FRIDA_GADGET" "$GAME_DIR/frida-gadget.dll"

for name in frida-gadget.config frida-gadget.config.json; do
    if [ -f "$GAME_DIR/$name" ]; then
        cp "$GAME_DIR/$name" "$OUT/$name.bak"
    fi
done

restore() {
    for name in frida-gadget.config frida-gadget.config.json; do
        if [ -f "$OUT/$name.bak" ]; then
            cp "$OUT/$name.bak" "$GAME_DIR/$name"
        fi
    done
}
trap restore EXIT

cat > "$GAME_DIR/frida-gadget.config" <<'JSON'
{"interaction":{"type":"script","path":"mods/ingame.js"},"runtime":"qjs"}
JSON
cp "$GAME_DIR/frida-gadget.config" "$GAME_DIR/frida-gadget.config.json"

rm -f "$GAME_DIR/probe-result.json"
(
    cd "$GAME_DIR"
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="winhttp=n,b" \
        wine "$GAME_EXE" -batchmode -nographics -logFile - > "$OUT/game.log" 2>&1
) &
game_pid=$!

for _ in $(seq 1 "$TIMEOUT"); do
    if [ -f "$GAME_DIR/probe-result.json" ]; then
        break
    fi
    sleep 1
done

kill "$game_pid" 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true

if [ ! -f "$GAME_DIR/probe-result.json" ]; then
    echo "ingame: no probe-result.json" >&2
    tail -20 "$OUT/game.log" >&2 || true
    exit 1
fi

cp "$GAME_DIR/probe-result.json" "$OUT/probe-result.json"
cat "$OUT/probe-result.json"

if ! grep -q '"ok": true' "$OUT/probe-result.json"; then
    echo "ingame: probe failed" >&2
    exit 1
fi

echo "ingame: PASS"
