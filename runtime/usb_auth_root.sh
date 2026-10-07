#!/system/bin/sh
# Root-only USB Authenticate backend. Invoked only after explicit detection/enable.
set -eu
ACTION=${1:-}
APK=${2:-}
LIB=${3:-}
MODE=${4:-closed}
BACKEND=${5:-none}
PROFILE=${6:-none}
APP_PROCESS=${7:-/system/bin/app_process}
ROOT=${USBMANAGER_STATE_DIR:?Missing state directory}
HOSTS=$ROOT/hosts
RUN=$ROOT/session
MOUNT_STAGE=/data/local/tmp/usbmanager-auth-mount
DAEMON_CLASS=com.tiger.usbmanager.auth.UsbAuthDaemon
SCHEME_SCRIPT=${USBMANAGER_SCHEME_SCRIPT:?Missing scheme implementation}
. "$SCHEME_SCRIPT"

# ReSukiSU can grant UID 0 while leaving the caller in the app mount namespace.
# Being able to list /data/adb does not prove that a bind mount will be visible
# to an init-managed HAL. Always re-enter its global mount namespace once when
# ksud is present; Magisk and ordinary KernelSU continue directly.
if [ "${USBMANAGER_GLOBAL:-0}" != 1 ] && [ -x /data/adb/ksud ] && [ "$ACTION" != list ] && [ "$ACTION" != delete ] && [ "$ACTION" != edit ]; then
    OUTER_ADB=$(settings get global adb_enabled 2>/dev/null || echo 0)
    OUTER_FUNCTIONS=$(svc usb getFunctions 2>/dev/null || echo none)
    scheme_before_global
    STATUS=0
    OUTPUT=$(printf 'USBMANAGER_GLOBAL=1 USBMANAGER_PARENT_ADB=%s USBMANAGER_STATE_DIR=%s USBMANAGER_SCHEME_SCRIPT=%s sh %s %s %s %s %s %s %s %s\nexit\n' \
        "$OUTER_ADB" "$ROOT" "$SCHEME_SCRIPT" "$0" "$ACTION" "$APK" "$LIB" "$MODE" "$BACKEND" "$PROFILE" "$APP_PROCESS" | /data/adb/ksud debug su -g) || STATUS=$?
    printf '%s\n' "$OUTPUT"
    RESTORE_LINE=$(printf '%s\n' "$OUTPUT" | grep '^FRAMEWORK_RESTORE ' | tail -n 1 || true)
    if [ -n "$RESTORE_LINE" ]; then
        : # The global root session has already restored the framework and gadget.
    elif [ "$ACTION" = start ] && ! printf '%s\n' "$OUTPUT" | grep -q '^STARTED$'; then
        settings put global adb_enabled 0
        svc usb setFunctions "$OUTER_FUNCTIONS"
        settings put global adb_enabled "$OUTER_ADB"
        [ "$OUTER_ADB" != 1 ] || setprop ctl.start adbd
    fi
    case "$ACTION" in
      detect) printf '%s\n' "$OUTPUT" | grep -q '^BACKEND=' && exit 0 ;;
      start) printf '%s\n' "$OUTPUT" | grep -q '^STARTED$' && exit 0 ;;
      restore) printf '%s\n' "$OUTPUT" | grep -q '^FRAMEWORK_RESTORE ' && exit 0 ;;
      list) exit 0 ;;
      delete) printf '%s\n' "$OUTPUT" | grep -q '^DELETED$' && exit 0 ;;
    esac
    exit "$STATUS"
fi

mkdir -p "$ROOT" "$HOSTS"
chmod 700 "$ROOT" "$HOSTS"

trace() { echo "$(date +%s%3N) $*" >> "$ROOT/last-session.log"; }

daemon_start() {
    MOUNT=$1
    PAIR=$2
    LOG=$3
    RESULT=$4
    rm -f "$RESULT" "$RESULT.tmp"
    CLASSPATH="$APK" "$APP_PROCESS" /system/bin "$DAEMON_CLASS" "$LIB" "$MOUNT" "$HOSTS" "$PAIR" "$RESULT" "$PROFILE" > "$LOG" 2>&1 &
    DAEMON=$!
    [ ! -d "$RUN" ] || echo "$DAEMON" > "$RUN/daemon.pid"
    # app_process normally becomes ready in well under a second. Polling once per
    # second added a full second to every cable insertion on the common path.
    for i in $(seq 1 30); do grep -q '^READY ' "$LOG" && return 0; sleep 0.1; done
    kill "$DAEMON" 2>/dev/null || true
    return 1
}

standard_composition_ready() {
    EXPECTED_DATA=$1
    EXPECTED_ADB=$2
    CURRENT_LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
    echo "$CURRENT_LINKS" | grep -q ffs.qxr && return 1
    for FUNCTION in mtp ptp rndis midi accessory audio_source ncm; do
        case ",$EXPECTED_DATA," in
          *,$FUNCTION,*) echo "$CURRENT_LINKS" | grep -q "\.$FUNCTION" || return 1 ;;
          *) echo "$CURRENT_LINKS" | grep -q "\.$FUNCTION" && return 1 ;;
        esac
    done
    if [ "$EXPECTED_ADB" = 1 ]; then
        echo "$CURRENT_LINKS" | grep -q ffs.adb || return 1
    else
        echo "$CURRENT_LINKS" | grep -q ffs.adb && return 1
    fi
    return 0
}

wait_standard_composition() {
    EXPECTED_DATA=$1
    EXPECTED_ADB=$2
    LIMIT=$3
    REQUIRED_STABLE=${4:-3}
    STABLE=0
    for i in $(seq 1 "$LIMIT"); do
        if standard_composition_ready "$EXPECTED_DATA" "$EXPECTED_ADB"; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -lt "$REQUIRED_STABLE" ] || return 0
        else
            STABLE=0
        fi
        sleep 0.1
    done
    return 1
}

common_capability() {
    [ "$(id -u)" = 0 ] || return 1
    [ -r "$APK" ] && [ -r "$LIB" ] || return 1
    CLASSPATH="$APK" "$APP_PROCESS" /system/bin "$DAEMON_CLASS" self-test "$LIB" > "$ROOT/runtime-check.log" 2>&1 || return 1
    grep -qx NATIVE_READY "$ROOT/runtime-check.log" || return 1
    [ -d /config/usb_gadget ] || return 1
    grep -qw functionfs /proc/filesystems || return 1
    [ -n "$(ls /sys/class/udc 2>/dev/null)" ] || return 1
}




save_state() {
    mkdir "$RUN" || return 1
    getprop vendor.usb.config > "$RUN/vendor-config"
    getprop persist.vendor.usb.config.extra > "$RUN/extra"
    LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
    if [ -n "${USBMANAGER_PARENT_ADB:-}" ]; then
        echo "$USBMANAGER_PARENT_ADB" > "$RUN/adb"
    elif echo "$LINKS" | grep -q ffs.adb; then echo 1 > "$RUN/adb"; else echo 0 > "$RUN/adb"; fi
    COMPOSITION=''
    for NAME in mtp ptp rndis midi accessory audio_source ncm qxr adb; do
        echo "$LINKS" | grep -q "\.$NAME" || continue
        if [ -n "$COMPOSITION" ]; then COMPOSITION="$COMPOSITION,$NAME"; else COMPOSITION=$NAME; fi
    done
    [ -n "$COMPOSITION" ] || COMPOSITION=none
    echo "$COMPOSITION" > "$RUN/functions"
}



restore() {
    [ -d "$RUN" ] || return 0
    mkdir "$RUN/restoring" 2>/dev/null || true
    rm -f "$RUN/watchdog.armed"
    trace "restore begin"
    [ ! -f "$RUN/daemon.log" ] || cp "$RUN/daemon.log" "$ROOT/last-daemon.log"
    [ ! -f "$RUN/watchdog.log" ] || cp "$RUN/watchdog.log" "$ROOT/last-watchdog.log"
    [ ! -f "$RUN/daemon.pid" ] || kill "$(cat "$RUN/daemon.pid")" 2>/dev/null || true
    sleep 0.3
    SAVED_ADB=$(cat "$RUN/adb")
    SAVED_FUNCTIONS=$(cat "$RUN/functions")
    scheme_restore
    echo "FRAMEWORK_RESTORE $SAVED_ADB $SAVED_FUNCTIONS"
    trace "restore complete adb=$SAVED_ADB functions=$SAVED_FUNCTIONS"
    rm -rf "$RUN"
}

arm_watchdog() {
    cp "$0" "$RUN/script"
    cp "$SCHEME_SCRIPT" "$RUN/scheme.sh"
    echo "$APK" > "$RUN/apk"
    echo "$LIB" > "$RUN/lib"
    WATCHDOG_TOKEN="$$-$(date +%s)"
    echo "$WATCHDOG_TOKEN" > "$RUN/watchdog.armed"
    nohup sh -c '
        sleep 120
        R=$1; STATE=$2; TOKEN=$3
        [ "$(cat "$R/watchdog.armed" 2>/dev/null || true)" = "$TOKEN" ] || exit 0
        USBMANAGER_STATE_DIR="$STATE" USBMANAGER_SCHEME_SCRIPT="$R/scheme.sh" sh "$R/script" restore "$(cat "$R/apk")" "$(cat "$R/lib")"
    ' usb-scheme-watchdog "$RUN" "$ROOT" "$WATCHDOG_TOKEN" > "$RUN/watchdog.log" 2>&1 < /dev/null &
}

release_operation() {
    rm -f "$ROOT/operation.lock/pid" "$ROOT/operation.lock/action" "$ROOT/operation.lock/birth"
    rmdir "$ROOT/operation.lock" 2>/dev/null || true
}

case "$ACTION" in
  detect|start|restore|edit|delete)
    if ! mkdir "$ROOT/operation.lock" 2>/dev/null; then
        OWNER=$(cat "$ROOT/operation.lock/pid" 2>/dev/null || true)
        case "$OWNER" in
          ''|*[!0-9]*) echo BUSY; exit 4 ;;
        esac
        BIRTH=$(cat "$ROOT/operation.lock/birth" 2>/dev/null || true)
        LIVE_BIRTH=$(awk '{print $22}' "/proc/$OWNER/stat" 2>/dev/null || true)
        if kill -0 "$OWNER" 2>/dev/null && [ -n "$BIRTH" ] && [ "$BIRTH" = "$LIVE_BIRTH" ]; then
            OWNER_ACTION=$(cat "$ROOT/operation.lock/action" 2>/dev/null || true)
            case "$ACTION:$OWNER_ACTION" in
              restore:start|restore:detect)
                kill "$OWNER" 2>/dev/null || true
                for i in $(seq 1 100); do kill -0 "$OWNER" 2>/dev/null || break; sleep 0.1; done
                kill -0 "$OWNER" 2>/dev/null && { echo BUSY; exit 4; }
                ;;
              *) echo BUSY; exit 4 ;;
            esac
        fi
        rm -f "$ROOT/operation.lock/pid" "$ROOT/operation.lock/action" "$ROOT/operation.lock/birth"
        rmdir "$ROOT/operation.lock" 2>/dev/null || true
        mkdir "$ROOT/operation.lock" 2>/dev/null || { echo BUSY; exit 4; }
    fi
    echo $$ > "$ROOT/operation.lock/pid"
    echo "$ACTION" > "$ROOT/operation.lock/action"
    awk '{print $22}' "/proc/$$/stat" > "$ROOT/operation.lock/birth"
    trap 'release_operation' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    ;;
esac

case "$ACTION" in
  detect)
    set +e
    [ ! -d "$RUN" ] || restore
    common_capability
    [ $? = 0 ] || { echo UNSUPPORTED; exit 3; }
    scheme_probe
    [ $? != 0 ] || { echo BACKEND=$BACKEND; exit 0; }
    echo UNSUPPORTED; exit 3
    ;;
  start)
    [ "$MODE" = closed ] || [ "$MODE" = pair ]
    # A closed recognition session may already be active for this cable. Pairing
    # replaces it atomically by restoring the saved gadget state first.
    [ ! -d "$RUN" ] || restore
    rm -rf "$RUN"; save_state
    : > "$ROOT/last-session.log"
    trace "start requested mode=$MODE backend=$BACKEND saved_adb=$(cat "$RUN/adb") saved_functions=$(cat "$RUN/functions")"
    trap 'restore; release_operation' EXIT
    arm_watchdog
    scheme_prepare
    echo STARTED
    AUTH_RESULT=TIMEOUT
    ATTEMPTS=20
    [ "$MODE" != pair ] || ATTEMPTS=120
    for i in $(seq 1 "$ATTEMPTS"); do
        if [ -s "$RUN/auth-result" ]; then
            AUTH_RESULT=$(cat "$RUN/auth-result")
            if [ "$MODE" = pair ]; then
                case "$AUTH_RESULT" in
                  PAIRED\|*|KNOWN\|*) ;;
                  *) AUTH_RESULT=TIMEOUT; sleep 0.5; continue ;;
                esac
            fi
            # Give nativeSend time to deliver the encrypted response before teardown.
            sleep 0.5
            break
        fi
        sleep 0.5
    done
    restore
    trap 'release_operation' EXIT
    # Pairing also applies its durable profile before reporting completion.
    case "$AUTH_RESULT" in
      PAIRED\|*|KNOWN\|*)
        if [ "$MODE" = pair ]; then
            APPLY_MODE=$(printf '%s' "$AUTH_RESULT" | cut -d '|' -f 4)
            APPLY_ADB=$(printf '%s' "$AUTH_RESULT" | cut -d '|' -f 5)
            case "$APPLY_MODE:$APPLY_ADB" in
              none:true|none:false|mtp:true|mtp:false|ptp:true|ptp:false|rndis:true|rndis:false|midi:true|midi:false)
                if [ "$APPLY_ADB" = true ]; then settings put global adb_enabled 1; else settings put global adb_enabled 0; fi
                [ "$APPLY_MODE" != none ] || APPLY_MODE=''
                svc usb setFunctions "$APPLY_MODE"
                ;;
            esac
        fi
        ;;
    esac
    printf 'AUTH_RESULT %s\n' "$AUTH_RESULT"
    ;;
  restore)
    restore
    ;;
  list)
    CLASSPATH="$APK" "$APP_PROCESS" /system/bin "$DAEMON_CLASS" list "$HOSTS"
    ;;
  edit)
    CLASSPATH="$APK" "$APP_PROCESS" /system/bin "$DAEMON_CLASS" edit "$HOSTS" "$MODE" "$PROFILE"
    ;;
  delete)
    ID=$MODE
    echo "$ID" | grep -qE '^[0-9a-f]{64}$'
    rm -f "$HOSTS/$ID.properties" "$HOSTS/$ID.entry"
    echo DELETED
    ;;
  *)
    echo 'usage: usb_auth_root.sh detect|start|restore|list|edit|delete' >&2
    exit 2
    ;;
esac
