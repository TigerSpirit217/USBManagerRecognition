#!/system/bin/sh
# USBManager scheme package interface v1. No vendor logic lives in the Android app.
set -eu
BACKEND=generic_configfs
ACTION=${1:?Missing action}
STATE=${2:?Missing state directory}
ABI=${3:?Missing ABI}
APP_PROCESS=${4:?Missing Android runtime}
MODE=${5:-closed}
PROFILE=${6:-none}
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APK=$BASE/runtime/daemon.jar
LIB=$BASE/lib/$ABI/libusbmanager_auth.so
mkdir -p "$STATE/hosts"
chmod 700 "$STATE" "$STATE/hosts"
# Keep existing trust records when moving from the former built-in schemes.
if [ ! -e "$STATE/.legacy-migrated" ]; then
    if [ -d /data/adb/usbmanager-auth/hosts ]; then
        for RECORD in /data/adb/usbmanager-auth/hosts/*.properties /data/adb/usbmanager-auth/hosts/*.entry; do
            [ -f "$RECORD" ] || continue
            TARGET=$STATE/hosts/$(basename "$RECORD")
            [ -e "$TARGET" ] || cp "$RECORD" "$TARGET"
        done
    fi
    touch "$STATE/.legacy-migrated"
fi
set +e
OUTPUT=$(USBMANAGER_STATE_DIR="$STATE" USBMANAGER_SCHEME_SCRIPT="$BASE/scheme.sh" sh "$BASE/runtime/usb_auth_root.sh" "$ACTION" "$APK" "$LIB" "$MODE" "$BACKEND" "$PROFILE" "$APP_PROCESS" 2>&1)
STATUS=$?
set -e
printf '%s\n' "$OUTPUT"
case "$ACTION" in
  detect)
    if [ "$STATUS" = 0 ] && printf '%s\n' "$OUTPUT" | grep -qx "BACKEND=$BACKEND"; then echo 'USBMGR_SUPPORTED 1'; else echo 'USBMGR_SUPPORTED 0'; exit 3; fi
    ;;
  restore)
    [ "$STATUS" = 0 ] || exit "$STATUS"
    echo USBMGR_RESTORED
    ;;
  start|list|edit|delete) exit "$STATUS" ;;
  *) echo 'Unknown action' >&2; exit 2 ;;
esac