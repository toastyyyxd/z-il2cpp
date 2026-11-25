#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_DIR/zig-out/ingame"
BACKUP="$OUT/config-backup"
GAME_DIR="${GAME_DIR:?set GAME_DIR}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
PORT="${PORT:-27042}"

if [ "${1:-}" = "stop" ]; then
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    if [ -d "$BACKUP" ]; then
        cp "$BACKUP"/* "$GAME_DIR"/ 2>/dev/null || true
        rm -rf "$BACKUP"
    fi
    echo "session: stopped"
    exit 0
fi

FRIDA_GADGET="${FRIDA_GADGET:?set FRIDA_GADGET}"
GAME_EXE="${GAME_EXE:-game.exe}"
HEADED="${HEADED:-0}"

if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    echo "session: already running on 127.0.0.1:$PORT"
    exit 0
fi

mkdir -p "$OUT"
zig build shared

rm -rf "$GAME_DIR/shared"
mkdir -p "$GAME_DIR/shared"
cp "$REPO_DIR"/zig-out/shared/* "$GAME_DIR/shared/"
cp "$FRIDA_GADGET" "$GAME_DIR/frida-gadget.dll"

if [ ! -d "$BACKUP" ]; then
    mkdir -p "$BACKUP"
    for name in frida-gadget.config frida-gadget.config.json; do
        if [ -f "$GAME_DIR/$name" ]; then
            cp "$GAME_DIR/$name" "$BACKUP/$name"
        fi
    done
fi

cat > "$GAME_DIR/frida-gadget.config" <<JSON
{"interaction":{"type":"listen","address":"127.0.0.1","port":$PORT},"runtime":"qjs"}
JSON
cp "$GAME_DIR/frida-gadget.config" "$GAME_DIR/frida-gadget.config.json"

ARGS=""
if [ "$HEADED" != "1" ]; then
    ARGS="-batchmode -nographics"
fi

setsid nohup bash -c 'cd "$1" && exec env WINEPREFIX="$2" WINEDEBUG=-all WINEDLLOVERRIDES="winhttp=n,b" wine "$3" $4 -logFile -' _ "$GAME_DIR" "$WINEPREFIX" "$GAME_EXE" "$ARGS" > "$OUT/session.log" 2>&1 < /dev/null &
echo $! > "$OUT/session.pid"
disown

for _ in $(seq 1 120); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        echo "session: gadget listening on 127.0.0.1:$PORT"
        exit 0
    fi
    sleep 0.25
done

echo "session: gadget did not start, see $OUT/session.log" >&2
exit 1
