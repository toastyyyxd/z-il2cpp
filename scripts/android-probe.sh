#!/usr/bin/env bash
# Reinstrument a locally owned APK for testing. Use only on builds you are
# authorized to modify.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

BASE_APK=""
SPLIT_APK=""
KEYSTORE=""
KEY_PASS=""
KEY_ALIAS="zil2cpp"
PACKAGE=""
ACTIVITY=""
WORK_DIR="${WORK_DIR:-/tmp/zil2cpp-android}"
WAIT_SECONDS="${WAIT_SECONDS:-18}"
DEBUGGABLE=1
REPLACE_CLASSES=()
REMOVE_ACTIVITIES=()

usage() {
    cat <<'USAGE'
usage: android-probe.sh --base-apk PATH --keystore PATH --package NAME [options]

Required:
  --base-apk PATH        base APK to modify
  --keystore PATH        signing keystore
  --package NAME         application package name

Optional:
  --split-apk PATH       split APK containing native libraries
  --key-pass PASS        keystore/key password
  --key-alias NAME       key alias (default: zil2cpp)
  --activity NAME        launch activity; otherwise use the launcher intent
  --work-dir PATH        scratch directory (default: /tmp/zil2cpp-android)
  --wait SECONDS         seconds to wait after launch (default: 18)
  --no-debuggable        do not add android:debuggable
  --replace-class OLD=NEW
                         replace an android:name attribute value
  --remove-activity NAME
                         remove an activity element by android:name
  --help                 show this message

The script builds zig-out/android/libzil2cpp.so and injects it into the
APK's native library directory. Optional manifest edits are for local test
builds that block the probe.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base-apk) BASE_APK="$2"; shift 2 ;;
        --split-apk) SPLIT_APK="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --key-pass) KEY_PASS="$2"; shift 2 ;;
        --key-alias) KEY_ALIAS="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --activity) ACTIVITY="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --wait) WAIT_SECONDS="$2"; shift 2 ;;
        --no-debuggable) DEBUGGABLE=0; shift ;;
        --replace-class) REPLACE_CLASSES+=("$2"); shift 2 ;;
        --remove-activity) REMOVE_ACTIVITIES+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "android-probe: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$BASE_APK" ] || [ -z "$KEYSTORE" ] || [ -z "$PACKAGE" ]; then
    usage >&2
    exit 2
fi

for tool in zig adb apktool apksigner patchelf; do
    command -v "$tool" >/dev/null 2>&1 || { echo "android-probe: missing $tool" >&2; exit 1; }
done

LOG_PATH="/data/data/$PACKAGE/zil2cpp-log.txt"

echo "android: building"
zig build android -Dandroid-log-path="$LOG_PATH"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if [ -n "$SPLIT_APK" ]; then
    mkdir -p "$WORK_DIR/split"
    echo "android: unpacking split"
    python3 - "$SPLIT_APK" "$WORK_DIR/split" <<'PY'
import sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as archive:
    archive.extractall(out)
PY

    echo "android: adding probe dependency"
    patchelf --add-needed libzil2cpp.so "$WORK_DIR/split/lib/arm64-v8a/libmain.so"
    cp "$REPO_DIR/zig-out/android/libzil2cpp.so" "$WORK_DIR/split/lib/arm64-v8a/libzil2cpp.so"

    echo "android: repacking split"
    python3 - "$SPLIT_APK" "$WORK_DIR" <<'PY'
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

echo "android: decoding base"
apktool d -f "$BASE_APK" -o "$WORK_DIR/base-decoded" >/dev/null

echo "android: editing manifest"
python3 - "$WORK_DIR/base-decoded/AndroidManifest.xml" "$DEBUGGABLE" "${REPLACE_CLASSES[@]}" -- "${REMOVE_ACTIVITIES[@]}" <<'PY'
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
    pattern = re.compile(r'\s*<activity\b[^>]*android:name="' + re.escape(name) + r'"[^>]*/>')
    text = pattern.sub("", text)
    pattern = re.compile(r'\s*<activity\b[^>]*android:name="' + re.escape(name) + r'"[^>]*>.*?</activity>', re.S)
    text = pattern.sub("", text)

if debuggable:
    if "android:debuggable=" in text:
        text = re.sub(r'android:debuggable="[^"]*"', 'android:debuggable="true"', text)
    else:
        text = re.sub(r'(<application\b[^>]*)', r'\1 android:debuggable="true"', text, count=1)

open(path, "w", encoding="utf-8").write(text)
PY

echo "android: rebuilding base"
apktool b "$WORK_DIR/base-decoded" -o "$WORK_DIR/base-unsigned.apk" >/dev/null

echo "android: signing"
SIGN_ARGS=(--ks "$KEYSTORE" --key-pass "pass:${KEY_PASS}" --ks-pass "pass:${KEY_PASS}")
apksigner sign "${SIGN_ARGS[@]}" --out "$WORK_DIR/base-signed.apk" "$WORK_DIR/base-unsigned.apk"
INSTALL_APKS=("$WORK_DIR/base-signed.apk")
if [ -n "$SPLIT_APK" ]; then
    apksigner sign "${SIGN_ARGS[@]}" --out "$WORK_DIR/split-signed.apk" "$WORK_DIR/split-new.apk"
    INSTALL_APKS+=("$WORK_DIR/split-signed.apk")
fi

echo "android: installing"
adb install-multiple -r "${INSTALL_APKS[@]}" >/dev/null
adb shell am force-stop "$PACKAGE"
adb logcat -c
if [ -n "$ACTIVITY" ]; then
    adb shell am start -n "$PACKAGE/$ACTIVITY" >/dev/null
else
    adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null
fi

echo "android: waiting $WAIT_SECONDS seconds"
sleep "$WAIT_SECONDS"
adb shell run-as "$PACKAGE" cat "$LOG_PATH" 2>/dev/null || echo "android: no log file"
