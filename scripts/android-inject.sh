#!/usr/bin/env bash
# Inject a native library into an APK you are authorized to modify, apply
# optional manifest edits, and sign the result.
set -euo pipefail

BASE_APK=""
SPLIT_APK=""
LIBRARY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zig-out/android/libzil2cpp.so"
OUT_DIR="$(dirname "${BASH_SOURCE[0]}")/../zig-out/inject"
KEYSTORE=""
KEY_PASS=""
KEY_ALIAS="zil2cpp"
DEBUGGABLE=1
REPLACE_CLASSES=()
REMOVE_ACTIVITIES=()

usage() {
    cat <<'USAGE'
usage: android-inject.sh --base-apk PATH --library PATH --keystore PATH [options]

Required:
  --base-apk PATH        base APK
  --keystore PATH        signing keystore

Optional:
  --split-apk PATH       split APK containing lib/arm64-v8a/libmain.so
  --library PATH         native library to inject (default: zig-out/android/libzil2cpp.so)
  --out-dir PATH         output directory (default: zig-out/inject)
  --key-pass PASS        keystore/key password
  --key-alias NAME       key alias (default: zil2cpp)
  --no-debuggable        do not add android:debuggable
  --replace-class OLD=NEW
                         replace an android:name attribute value
  --remove-activity NAME
                         remove an activity element by android:name

Writes base-signed.apk and, when --split-apk is used, split-signed.apk.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base-apk) BASE_APK="$2"; shift 2 ;;
        --split-apk) SPLIT_APK="$2"; shift 2 ;;
        --library) LIBRARY="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --key-pass) KEY_PASS="$2"; shift 2 ;;
        --key-alias) KEY_ALIAS="$2"; shift 2 ;;
        --no-debuggable) DEBUGGABLE=0; shift ;;
        --replace-class) REPLACE_CLASSES+=("$2"); shift 2 ;;
        --remove-activity) REMOVE_ACTIVITIES+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "android-inject: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$BASE_APK" ] || [ -z "$KEYSTORE" ]; then
    usage >&2
    exit 2
fi
for tool in apktool apksigner patchelf; do
    command -v "$tool" >/dev/null 2>&1 || { echo "android-inject: missing $tool" >&2; exit 1; }
done
if [ ! -f "$LIBRARY" ]; then
    echo "android-inject: library not found: $LIBRARY" >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [ -n "$SPLIT_APK" ]; then
    mkdir -p "$OUT_DIR/split"
    python3 - "$SPLIT_APK" "$OUT_DIR/split" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
PY
    patchelf --add-needed libzil2cpp.so "$OUT_DIR/split/lib/arm64-v8a/libmain.so"
    cp "$LIBRARY" "$OUT_DIR/split/lib/arm64-v8a/libzil2cpp.so"
    python3 - "$SPLIT_APK" "$OUT_DIR" <<'PY'
import sys, zipfile
src, work = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(work + "/split-new.apk", "w") as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        if info.filename == "lib/arm64-v8a/libmain.so":
            data = open(work + "/split/lib/arm64-v8a/libmain.so", "rb").read()
        entry = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        entry.compress_type = info.compress_type
        entry.external_attr = info.external_attr
        entry.create_system = info.create_system
        zout.writestr(entry, data)
    entry = zipfile.ZipInfo("lib/arm64-v8a/libzil2cpp.so", date_time=(2026, 11, 26, 9, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = 0o100755 << 16
    zout.writestr(entry, open(work + "/split/lib/arm64-v8a/libzil2cpp.so", "rb").read())
PY
fi

apktool d -f "$BASE_APK" -o "$OUT_DIR/base-decoded" >/dev/null
python3 - "$OUT_DIR/base-decoded/AndroidManifest.xml" "$DEBUGGABLE" "${REPLACE_CLASSES[@]}" -- "${REMOVE_ACTIVITIES[@]}" <<'PY'
import re, sys
path = sys.argv[1]
debuggable = sys.argv[2] == "1"
arguments = sys.argv[3:]
separator = arguments.index("--") if "--" in arguments else len(arguments)
replacements = arguments[:separator]
activities = arguments[separator + 1:] if separator < len(arguments) else []
text = open(path, "r", encoding="utf-8").read()
for item in replacements:
    old, new = item.split("=", 1)
    text = text.replace(f'android:name="{old}"', f'android:name="{new}"')
for name in activities:
    text = re.sub(r'\s*<activity\b[^>]*android:name="' + re.escape(name) + r'"[^>]*/>', "", text)
    text = re.sub(r'\s*<activity\b[^>]*android:name="' + re.escape(name) + r'"[^>]*>.*?</activity>', "", text, flags=re.S)
if debuggable:
    if "android:debuggable=" in text:
        text = re.sub(r'android:debuggable="[^"]*"', 'android:debuggable="true"', text)
    else:
        text = re.sub(r'(<application\b[^>]*)', r'\1 android:debuggable="true"', text, count=1)
open(path, "w", encoding="utf-8").write(text)
PY
apktool b "$OUT_DIR/base-decoded" -o "$OUT_DIR/base-unsigned.apk" >/dev/null

SIGN_ARGS=(--ks "$KEYSTORE" --key-pass "pass:${KEY_PASS}" --ks-pass "pass:${KEY_PASS}")
apksigner sign "${SIGN_ARGS[@]}" --out "$OUT_DIR/base-signed.apk" "$OUT_DIR/base-unsigned.apk"
if [ -n "$SPLIT_APK" ]; then
    apksigner sign "${SIGN_ARGS[@]}" --out "$OUT_DIR/split-signed.apk" "$OUT_DIR/split-new.apk"
fi
echo "android-inject: wrote $OUT_DIR/base-signed.apk"
if [ -n "$SPLIT_APK" ]; then
    echo "android-inject: wrote $OUT_DIR/split-signed.apk"
fi
