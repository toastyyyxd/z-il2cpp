#!/usr/bin/env bash
# Inject a native library into an APK you are authorized to modify, apply
# optional manifest edits, and sign the result.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BASE_APK=""
SPLIT_APK=""
LIBRARY="$ROOT_DIR/zig-out/android/libzil2cpp.so"
OUT_DIR="$ROOT_DIR/zig-out/inject"
KEYSTORE=""
KEY_PASS=""
KEY_ALIAS="zil2cpp"
DEBUGGABLE=1
KEEP_WORK=0
REPLACE_CLASSES=()
REMOVE_ACTIVITIES=()

WORK_DIR=""
STAGED_FILES=()

usage() {
    cat <<'USAGE'
usage: android-inject.sh --base-apk PATH --keystore PATH [options]

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
  --keep-work            keep the temporary work directory (prints its path)
  --replace-class OLD=NEW
                         replace an android:name attribute value
  --remove-activity NAME
                         remove an activity element by android:name

Writes base-signed.apk and, when --split-apk is used, split-signed.apk into
--out-dir, overwriting only those two files. The output directory is never
cleared; all intermediates live in a temporary directory.
USAGE
}

die() { echo "android-inject: $*" >&2; exit 1; }
need_val() { [ "$1" -ge 2 ] || die "option $2 requires a value"; }
abspath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

cleanup() {
    local f
    for f in ${STAGED_FILES[@]+"${STAGED_FILES[@]}"}; do
        [ -n "$f" ] && rm -f -- "$f"
    done
    # Only ever remove the mktemp directory this script created, never $OUT_DIR.
    if [ "$KEEP_WORK" -eq 0 ]; then
        case "$WORK_DIR" in
            */android-inject.????????*) rm -rf -- "$WORK_DIR" ;;
        esac
    fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --base-apk)        need_val $# "$1"; BASE_APK="$2"; shift 2 ;;
        --split-apk)       need_val $# "$1"; SPLIT_APK="$2"; shift 2 ;;
        --library)         need_val $# "$1"; LIBRARY="$2"; shift 2 ;;
        --out-dir)         need_val $# "$1"; OUT_DIR="$2"; shift 2 ;;
        --keystore)        need_val $# "$1"; KEYSTORE="$2"; shift 2 ;;
        --key-pass)        need_val $# "$1"; KEY_PASS="$2"; shift 2 ;;
        --key-alias)       need_val $# "$1"; KEY_ALIAS="$2"; shift 2 ;;
        --no-debuggable)   DEBUGGABLE=0; shift ;;
        --keep-work)       KEEP_WORK=1; shift ;;
        --replace-class)   need_val $# "$1"; REPLACE_CLASSES+=("$2"); shift 2 ;;
        --remove-activity) need_val $# "$1"; REMOVE_ACTIVITIES+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "android-inject: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$BASE_APK" ] || [ -z "$KEYSTORE" ]; then
    usage >&2
    exit 2
fi
for tool in apktool apksigner patchelf python3; do
    command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
done
[ -f "$BASE_APK" ] || die "base APK not found: $BASE_APK"
[ -f "$KEYSTORE" ] || die "keystore not found: $KEYSTORE"
[ -f "$LIBRARY" ]  || die "library not found: $LIBRARY"
BASE_APK="$(abspath "$BASE_APK")"
KEYSTORE="$(abspath "$KEYSTORE")"
LIBRARY="$(abspath "$LIBRARY")"
if [ -n "$SPLIT_APK" ]; then
    [ -f "$SPLIT_APK" ] || die "split APK not found: $SPLIT_APK"
    SPLIT_APK="$(abspath "$SPLIT_APK")"
fi

mkdir -p -- "$OUT_DIR"
OUT_DIR="$(cd -- "$OUT_DIR" && pwd)"

BASE_OUT="$OUT_DIR/base-signed.apk"
SPLIT_OUT="$OUT_DIR/split-signed.apk"

# Refuse to clobber an input, or to "overwrite" something that isn't a file.
check_output() {
    local out="$1" src
    for src in "$BASE_APK" "$SPLIT_APK" "$LIBRARY" "$KEYSTORE"; do
        [ -n "$src" ] || continue
        [ "$out" != "$src" ] || die "refusing to overwrite input file: $out"
    done
    if [ -e "$out" ] && [ ! -f "$out" ]; then
        die "output path is not a regular file: $out"
    fi
}
check_output "$BASE_OUT"
[ -z "$SPLIT_APK" ] || check_output "$SPLIT_OUT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/android-inject.XXXXXXXX")"

SIGN_ARGS=(--ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS"
           --key-pass "pass:${KEY_PASS}" --ks-pass "pass:${KEY_PASS}")

# Sign to a staging file in $OUT_DIR, then rename over the destination so a
# failed run never leaves a half-written APK behind.
sign_apk() {
    local input="$1" output="$2" staged
    staged="$(mktemp "$OUT_DIR/.tmp-signed.XXXXXX")"
    STAGED_FILES+=("$staged")
    apksigner sign "${SIGN_ARGS[@]}" --out "$staged" "$input"
    mv -f -- "$staged" "$output"
}

if [ -n "$SPLIT_APK" ]; then
    SPLIT_WORK="$WORK_DIR/split"
    mkdir -p "$SPLIT_WORK/lib/arm64-v8a"
    python3 - "$SPLIT_APK" "$SPLIT_WORK" <<'PY'
import shutil, sys, zipfile
src, work = sys.argv[1], sys.argv[2]
name = "lib/arm64-v8a/libmain.so"
with zipfile.ZipFile(src) as archive:
    if name not in archive.namelist():
        sys.exit("android-inject: split APK has no " + name)
    with archive.open(name) as fin, open(work + "/" + name, "wb") as fout:
        shutil.copyfileobj(fin, fout)
PY
    if ! patchelf --print-needed "$SPLIT_WORK/lib/arm64-v8a/libmain.so" | grep -qx "libzil2cpp.so"; then
        patchelf --add-needed libzil2cpp.so "$SPLIT_WORK/lib/arm64-v8a/libmain.so"
    fi
    cp -f -- "$LIBRARY" "$SPLIT_WORK/lib/arm64-v8a/libzil2cpp.so"
    python3 - "$SPLIT_APK" "$SPLIT_WORK" "$WORK_DIR/split-new.apk" <<'PY'
import sys, zipfile
src, work, out = sys.argv[1], sys.argv[2], sys.argv[3]
LIBMAIN = "lib/arm64-v8a/libmain.so"
INJECT = "lib/arm64-v8a/libzil2cpp.so"
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
    for info in zin.infolist():
        if info.filename == INJECT:
            continue  # already-injected input: replace instead of duplicating
        if info.filename == LIBMAIN:
            data = open(work + "/" + LIBMAIN, "rb").read()
        else:
            data = zin.read(info)
        entry = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        entry.compress_type = info.compress_type
        entry.external_attr = info.external_attr
        entry.internal_attr = info.internal_attr
        entry.create_system = info.create_system
        zout.writestr(entry, data)
    entry = zipfile.ZipInfo(INJECT, date_time=(2026, 11, 26, 9, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = 0o100755 << 16
    entry.create_system = 3
    zout.writestr(entry, open(work + "/" + INJECT, "rb").read())
PY
fi

apktool d -f "$BASE_APK" -o "$WORK_DIR/base-decoded" >/dev/null
python3 - "$WORK_DIR/base-decoded/AndroidManifest.xml" "$DEBUGGABLE" \
    ${REPLACE_CLASSES[@]+"${REPLACE_CLASSES[@]}"} -- ${REMOVE_ACTIVITIES[@]+"${REMOVE_ACTIVITIES[@]}"} <<'PY'
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
apktool b "$WORK_DIR/base-decoded" -o "$WORK_DIR/base-unsigned.apk" >/dev/null

sign_apk "$WORK_DIR/base-unsigned.apk" "$BASE_OUT"
echo "android-inject: wrote $BASE_OUT"
if [ -n "$SPLIT_APK" ]; then
    sign_apk "$WORK_DIR/split-new.apk" "$SPLIT_OUT"
    echo "android-inject: wrote $SPLIT_OUT"
fi
if [ "$KEEP_WORK" -eq 1 ]; then
    echo "android-inject: work dir kept at $WORK_DIR"
fi
