#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRIDA_GADGET="${FRIDA_GADGET:-}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/zig-out/smoke}"
LAYOUT_DIR="$OUT_DIR/layout"
WINEPREFIX="${WINEPREFIX:-$OUT_DIR/wineprefix}"
TIMEOUT="${TIMEOUT:-60}"

fail() {
    echo "smoke: $*" >&2
    exit 1
}

case "$(realpath -m -- "$OUT_DIR")" in
    "$REPO_DIR"/*|"${TMPDIR:-/tmp}"/*) ;;
    *) fail "OUT_DIR must be under $REPO_DIR or ${TMPDIR:-/tmp} (got $OUT_DIR)" ;;
esac

command -v zig >/dev/null 2>&1 || fail "zig not found (nix develop / direnv shell)"

command -v zig >/dev/null 2>&1 || fail "zig not found (nix develop / direnv shell)"
command -v wine >/dev/null 2>&1 || fail "wine not found"

if [ -z "$FRIDA_GADGET" ] || [ ! -f "$FRIDA_GADGET" ]; then
    fail "set FRIDA_GADGET=/path/to/frida-gadget-<ver>-windows-x86_64.dll (https://github.com/frida/frida/releases)"
fi

echo "smoke: building shared artifacts and host"
zig build shared smoke-host

echo "smoke: laying out $LAYOUT_DIR"
rm -rf -- "$LAYOUT_DIR"
mkdir -p -- "$LAYOUT_DIR/shared" "$LAYOUT_DIR/mods"
cp "$FRIDA_GADGET" "$LAYOUT_DIR/frida-gadget.dll"
cp "$REPO_DIR/tests/smoke/agent.js" "$LAYOUT_DIR/mods/agent.js"
cat > "$LAYOUT_DIR/frida-gadget.config" <<'JSON'
{"interaction":{"type":"script","path":"mods/agent.js"},"runtime":"qjs"}
JSON
cp "$LAYOUT_DIR/frida-gadget.config" "$LAYOUT_DIR/frida-gadget.config.json"
cp "$REPO_DIR"/zig-out/shared/* "$LAYOUT_DIR/shared/"
cp "$REPO_DIR/zig-out/smoke/smoke-host.exe" "$LAYOUT_DIR/host.exe"

echo "smoke: running under wine (prefix $WINEPREFIX)"
(
    cd "$LAYOUT_DIR"
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all timeout "$TIMEOUT" wine host.exe >run.log 2>&1 || true
)

if [ ! -f "$LAYOUT_DIR/smoke-result.json" ]; then
    echo "smoke: no smoke-result.json (gadget script did not run)" >&2
    tail -20 "$LAYOUT_DIR/run.log" >&2 || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    exit 1
fi

echo "smoke: result"
cat "$LAYOUT_DIR/smoke-result.json"

status=0
grep -q '"ok": true' "$LAYOUT_DIR/smoke-result.json" || status=1
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true

if [ "$status" -ne 0 ]; then
    fail "shared-library smoke test failed (see $LAYOUT_DIR/smoke-result.json)"
fi
echo "smoke: PASS"
