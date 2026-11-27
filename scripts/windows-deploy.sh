#!/usr/bin/env bash
# Copy shared libraries, a Frida gadget, agents, or arbitrary files into a
# Windows game directory.
set -euo pipefail

GAME_DIR=""
SHARED_DIR=""
GADGET=""
FRIDA_CONFIG=""
AGENTS=()
COPIES=()

usage() {
    cat <<'USAGE'
usage: windows-deploy.sh --game-dir DIR [options]

Options:
  --shared-dir PATH      copy contents to DIR/shared (replaces it)
  --gadget PATH          copy to DIR/frida-gadget.dll
  --frida-config JSON    write DIR/frida-gadget.config and .json
  --agent SRC:DEST       copy an agent to DIR/DEST (repeatable)
  --copy SRC:DEST        copy any file to DIR/DEST (repeatable)
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --shared-dir) SHARED_DIR="$2"; shift 2 ;;
        --gadget) GADGET="$2"; shift 2 ;;
        --frida-config) FRIDA_CONFIG="$2"; shift 2 ;;
        --agent) AGENTS+=("$2"); shift 2 ;;
        --copy) COPIES+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "windows-deploy: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ -z "$GAME_DIR" ]; then
    usage >&2
    exit 2
fi
GAME_DIR=$(realpath -m -- "$GAME_DIR")
case "$GAME_DIR" in
    /|/home|/root|/usr|/etc|/var|/nix|"$HOME")
        echo "windows-deploy: refusing GAME_DIR=$GAME_DIR" >&2; exit 1 ;;
esac
[ -d "$GAME_DIR" ] || { echo "windows-deploy: no game directory: $GAME_DIR" >&2; exit 1; }

if [ -n "$SHARED_DIR" ]; then
    rm -- -rf "$GAME_DIR/shared"
    mkdir -- -p "$GAME_DIR/shared"
    cp -- "$SHARED_DIR"/* "$GAME_DIR/shared/"
fi
if [ -n "$GADGET" ]; then
    cp "$GADGET" "$GAME_DIR/frida-gadget.dll"
fi
if [ -n "$FRIDA_CONFIG" ]; then
    printf '%s\n' "$FRIDA_CONFIG" > "$GAME_DIR/frida-gadget.config"
    cp "$GAME_DIR/frida-gadget.config" "$GAME_DIR/frida-gadget.config.json"
fi

copy_pairs() {
    local pair="$1"
    local src="${pair%%:*}"
    local dest="${pair#*:}"
    if [ "$src" = "$dest" ] || [ -z "$dest" ]; then
        echo "windows-deploy: expected SRC:DEST, got $pair" >&2
        exit 2
    fi
    local dest_abs
    dest_abs=$(realpath -m -- "$GAME_DIR/$dest")
    case "$dest_abs" in
        "$GAME_DIR"/*) ;;
        *) echo "windows-deploy: $pair escapes GAME_DIR" >&2; exit 2 ;;
    esac
    mkdir -p -- "$(dirname -- "$dest_abs")"
    cp -- "$src" "$dest_abs"
}
for pair in "${AGENTS[@]}"; do copy_pairs "$pair"; done
for pair in "${COPIES[@]}"; do copy_pairs "$pair"; done
