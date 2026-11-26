#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GAME_DIR="${GAME_DIR:?set GAME_DIR to a game directory}"
FRIDA_GADGET="${FRIDA_GADGET:?set FRIDA_GADGET to a windows gadget dll}"
GAME_EXE="${GAME_EXE:-game.exe}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
TIMEOUT="${TIMEOUT:-120}"
OUT="$REPO_DIR/zig-out/ingame"

mkdir -p "$OUT"
zig build shared

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
    "$REPO_DIR/scripts/wine-stop.sh" --prefix "$WINEPREFIX"
}
trap restore EXIT

"$REPO_DIR/scripts/windows-deploy.sh" \
    --game-dir "$GAME_DIR" \
    --shared-dir "$REPO_DIR/zig-out/shared" \
    --gadget "$FRIDA_GADGET" \
    --agent "$REPO_DIR/tests/ingame/agent.js:mods/ingame.js" \
    --frida-config '{"interaction":{"type":"script","path":"mods/ingame.js"},"runtime":"qjs"}'

rm -f "$GAME_DIR/probe-result.json"
"$REPO_DIR/scripts/wine-run.sh" \
    --game-dir "$GAME_DIR" --exe "$GAME_EXE" --prefix "$WINEPREFIX" \
    --log "$OUT/game.log" --background --batchmode --dll-override "winhttp=n,b" >/dev/null

"$REPO_DIR/scripts/wait-file.sh" --path "$GAME_DIR/probe-result.json" --timeout "$TIMEOUT"
"$REPO_DIR/scripts/wine-stop.sh" --prefix "$WINEPREFIX"

cp "$GAME_DIR/probe-result.json" "$OUT/probe-result.json"
cat "$OUT/probe-result.json"
grep -q '"ok": true' "$OUT/probe-result.json" || { echo "ingame: probe failed" >&2; exit 1; }
echo "ingame: PASS"
