#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_DIR/zig-out/ingame"
BACKUP="$OUT/config-backup"
GAME_DIR="${GAME_DIR:?set GAME_DIR}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
PORT="${PORT:-27042}"

if [ "${1:-}" = "stop" ]; then
    "$REPO_DIR/scripts/wine-stop.sh" --prefix "$WINEPREFIX"
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

if [ ! -d "$BACKUP" ]; then
    mkdir -p "$BACKUP"
    for name in frida-gadget.config frida-gadget.config.json; do
        if [ -f "$GAME_DIR/$name" ]; then
            cp "$GAME_DIR/$name" "$BACKUP/$name"
        fi
    done
fi

CONFIG="{\"interaction\":{\"type\":\"listen\",\"address\":\"127.0.0.1\",\"port\":$PORT},\"runtime\":\"qjs\"}"
"$REPO_DIR/scripts/windows-deploy.sh" \
    --game-dir "$GAME_DIR" \
    --shared-dir "$REPO_DIR/zig-out/shared" \
    --gadget "$FRIDA_GADGET" \
    --frida-config "$CONFIG"

RUN_ARGS=(--game-dir "$GAME_DIR" --exe "$GAME_EXE" --prefix "$WINEPREFIX" \
    --log "$OUT/session.log" --background --dll-override "winhttp=n,b")
if [ "$HEADED" != "1" ]; then
    RUN_ARGS+=(--batchmode)
fi
"$REPO_DIR/scripts/wine-run.sh" "${RUN_ARGS[@]}" > "$OUT/session.pid"
disown 2>/dev/null || true

for _ in $(seq 1 120); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        echo "session: gadget listening on 127.0.0.1:$PORT"
        exit 0
    fi
    sleep 0.25
done

echo "session: gadget did not start, see $OUT/session.log" >&2
exit 1
