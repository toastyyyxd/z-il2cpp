#!/usr/bin/env bash
# Run a Windows program under Wine, optionally in the background.
set -euo pipefail

GAME_DIR=""
EXE=""
PREFIX="${WINEPREFIX:-$HOME/.cache/wine-test}"
LOG="${LOG:-/tmp/zil2cpp-wine.log}"
BATCHMODE=0
BACKGROUND=0
DLL_OVERRIDES=""
TIMEOUT=""

usage() {
    cat <<'USAGE'
usage: wine-run.sh --game-dir DIR --exe NAME [options]

Options:
  --prefix PATH          Wine prefix (default: $WINEPREFIX or ~/.cache/wine-test)
  --log PATH             foreground/background log path
  --batchmode            add -batchmode -nographics -logFile -
  --dll-override VALUE   set WINEDLLOVERRIDES
  --background           start detached and print the pid
  --timeout SECONDS      foreground timeout
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --exe) EXE="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --log) LOG="$2"; shift 2 ;;
        --batchmode) BATCHMODE=1; shift ;;
        --dll-override) DLL_OVERRIDES="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "wine-run: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ -z "$GAME_DIR" ] || [ -z "$EXE" ]; then
    usage >&2
    exit 2
fi
command -v wine >/dev/null 2>&1 || { echo "wine-run: wine not found" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

ARGS=()
if [ "$BATCHMODE" = "1" ]; then
    ARGS+=(-batchmode -nographics)
fi
ARGS+=(-logFile -)

if [ "$BACKGROUND" = "1" ]; then
    env_cmd=(env WINEPREFIX="$PREFIX" WINEDEBUG=-all)
    if [ -n "$DLL_OVERRIDES" ]; then
        env_cmd+=("WINEDLLOVERRIDES=$DLL_OVERRIDES")
    fi
    env_cmd+=(wine "$EXE" "${ARGS[@]}")
    (
        cd "$GAME_DIR"
        setsid nohup "${env_cmd[@]}" > "$LOG" 2>&1 < /dev/null &
        echo $! > "$LOG.pid"
    )
    cat "$LOG.pid"
    exit 0
fi

cmd=(env WINEPREFIX="$PREFIX" WINEDEBUG=-all)
if [ -n "$DLL_OVERRIDES" ]; then
    cmd+=("WINEDLLOVERRIDES=$DLL_OVERRIDES")
fi
cmd+=(wine "$EXE" "${ARGS[@]}")
if [ -n "$TIMEOUT" ]; then
    cd "$GAME_DIR"
    exec timeout "$TIMEOUT" "${cmd[@]}" > "$LOG" 2>&1
fi
cd "$GAME_DIR"
exec "${cmd[@]}" > "$LOG" 2>&1
