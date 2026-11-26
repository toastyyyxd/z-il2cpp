#!/usr/bin/env bash
# Android probe acceptance: build, inject, install, launch, read result.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_APK=""
SPLIT_APK=""
KEYSTORE=""
KEY_PASS=""
PACKAGE=""
ACTIVITY=""
WORK_DIR="${WORK_DIR:-/tmp/zil2cpp-android-probe}"
WAIT_SECONDS="${WAIT_SECONDS:-18}"
INJECT_ARGS=()

usage() {
    cat <<'USAGE'
usage: android-probe.sh --base-apk PATH --keystore PATH --package NAME [options]

Required:
  --base-apk PATH        base APK
  --keystore PATH        signing keystore
  --package NAME         application package name

Optional:
  --split-apk PATH       split APK containing native libraries
  --key-pass PASS        keystore/key password
  --activity NAME        launch activity; otherwise use the launcher intent
  --work-dir PATH        scratch directory (default: /tmp/zil2cpp-android-probe)
  --wait SECONDS         seconds to wait after launch (default: 18)
  --no-debuggable        do not add android:debuggable
  --replace-class OLD=NEW
                         forward a manifest replacement to android-inject.sh
  --remove-activity NAME
                         forward an activity removal to android-inject.sh
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base-apk) BASE_APK="$2"; shift 2 ;;
        --split-apk) SPLIT_APK="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --key-pass) KEY_PASS="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --activity) ACTIVITY="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --wait) WAIT_SECONDS="$2"; shift 2 ;;
        --no-debuggable) INJECT_ARGS+=(--no-debuggable); shift ;;
        --replace-class) INJECT_ARGS+=(--replace-class "$2"); shift 2 ;;
        --remove-activity) INJECT_ARGS+=(--remove-activity "$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *) echo "android-probe: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$BASE_APK" ] || [ -z "$KEYSTORE" ] || [ -z "$PACKAGE" ]; then
    usage >&2
    exit 2
fi

LOG_PATH="/data/data/$PACKAGE/zil2cpp-log.txt"
INJECT_DIR="$WORK_DIR/injected"

cd "$REPO_DIR"
echo "android-probe: building"
zig build android -Dandroid-log-path="$LOG_PATH"

echo "android-probe: injecting"
INJECT_SPLIT_ARGS=()
if [ -n "$SPLIT_APK" ]; then
    INJECT_SPLIT_ARGS+=(--split-apk "$SPLIT_APK")
fi
"$REPO_DIR/scripts/android-inject.sh" \
    --base-apk "$BASE_APK" \
    "${INJECT_SPLIT_ARGS[@]}" \
    --library "$REPO_DIR/zig-out/android/libzil2cpp.so" \
    --out-dir "$INJECT_DIR" \
    --keystore "$KEYSTORE" \
    --key-pass "$KEY_PASS" \
    "${INJECT_ARGS[@]}"

APKS=("$INJECT_DIR/base-signed.apk")
if [ -f "$INJECT_DIR/split-signed.apk" ]; then
    APKS+=("$INJECT_DIR/split-signed.apk")
fi

echo "android-probe: installing"
"$REPO_DIR/scripts/android-install.sh" "${APKS[@]}"

echo "android-probe: launching"
LAUNCH_ARGS=(--package "$PACKAGE")
if [ -n "$ACTIVITY" ]; then
    LAUNCH_ARGS+=(--activity "$ACTIVITY")
fi
"$REPO_DIR/scripts/android-launch.sh" "${LAUNCH_ARGS[@]}"

echo "android-probe: waiting $WAIT_SECONDS seconds"
sleep "$WAIT_SECONDS"

echo "android-probe: result"
RESULT="$("$REPO_DIR/scripts/android-read-log.sh" --package "$PACKAGE" --path "$LOG_PATH" 2>/dev/null || true)"
if [ -z "$RESULT" ]; then
    echo "android-probe: no log at $LOG_PATH" >&2
    exit 1
fi
printf '%s\n' "$RESULT"
grep -q '^done$' <<<"$RESULT" || { echo "android-probe: probe did not finish" >&2; exit 1; }
echo "android-probe: PASS"
