#!/system/bin/sh
CONF=/vendor/etc/usb_compositions.conf
for CANDIDATE in /odm/etc/usb_compositions.conf /product/etc/usb_compositions.conf /vendor/etc/usb_compositions.conf; do
    [ -r "$CANDIDATE" ] && grep -q '^qxr,adb[[:space:]]' "$CANDIDATE" 2>/dev/null || continue
    CONF=$CANDIDATE
    break
done
QXR=/dev/usb-ffs/qxr

scheme_probe() {
    [ "$(getprop init.svc.vendor.usbgadget-hal-1-2)" = running ] || return 1
    grep -q '^qxr,adb[[:space:]]' "$CONF" || return 1
    [ -d /config/usb_gadget/g1 ] || return 1
    ls /sys/class/udc | grep -qv '^dummy_udc' || return 1
    [ -e "$QXR/ep0" ] && [ ! -e "$QXR/ep1" ] || return 1
    daemon_start "$QXR" closed "$ROOT/nothing-probe.log" "$ROOT/nothing-probe-result" || return 1
    kill "$DAEMON" 2>/dev/null || true
    for i in $(seq 1 50); do [ ! -e "$QXR/ep1" ] && return 0; sleep 0.1; done
    return 1
}

scheme_prepare() {
    trace "scheme_prepare begin mode=$MODE conf=$CONF shell_mnt=$(readlink /proc/self/ns/mnt 2>/dev/null || echo unknown) init_mnt=$(readlink /proc/1/ns/mnt 2>/dev/null || echo unknown)"
    grep -q '^qxr,adb[[:space:]]' "$CONF" || return 1
    [ -e "$QXR/ep0" ] && [ ! -e "$QXR/ep1" ] || return 1
    rm -rf "$MOUNT_STAGE"
    mkdir "$MOUNT_STAGE"
    chmod 700 "$MOUNT_STAGE"
    cp "$CONF" "$MOUNT_STAGE/patched.conf"
    echo 'mtp,qxr,adb  0x05C6  0xD003' >> "$MOUNT_STAGE/patched.conf"
    chmod 600 "$MOUNT_STAGE/patched.conf"
    chcon u:object_r:vendor_configs_file:s0 "$MOUNT_STAGE/patched.conf" 2>/dev/null || true
    mount --bind "$MOUNT_STAGE/patched.conf" "$CONF"
    trace "composition table mounted"
    for i in $(seq 1 80); do [ -e /dev/usb-ffs/mtp/ep1 ] && break; sleep 0.1; done
    [ -e /dev/usb-ffs/mtp/ep1 ] || return 1
    trace "mtp endpoints ready"
    daemon_start "$QXR" "$MODE" "$RUN/daemon.log" "$RUN/auth-result" || return 1
    trace "auth daemon ready pid=$DAEMON"
    echo "$DAEMON" > "$RUN/daemon.pid"
    OLD_HAL_PID=$(pidof android.hardware.usb.gadget@1.2-service-qti 2>/dev/null || true)
    setprop ctl.restart vendor.usbgadget-hal-1-2
    HAL_PID=''
    for i in $(seq 1 100); do
        HAL_PID=$(pidof android.hardware.usb.gadget@1.2-service-qti 2>/dev/null || true)
        [ "$(getprop init.svc.vendor.usbgadget-hal-1-2)" = running ] && [ -n "$HAL_PID" ] && [ "$HAL_PID" != "$OLD_HAL_PID" ] && break
        sleep 0.1
    done
    [ -n "$HAL_PID" ] && [ "$HAL_PID" != "$OLD_HAL_PID" ] || return 1
    # UsbDeviceManager reapplies MTP+ADB after the restarted HAL reconnects. Wait
    # for the actual ConfigFS links to settle instead of sleeping six seconds.
    wait_standard_composition mtp 1 50 10 || return 1
    HAL_ROWS=0
    [ -z "$HAL_PID" ] || HAL_ROWS=$(grep -c '^mtp,qxr,adb[[:space:]]' "/proc/$HAL_PID/root$CONF" 2>/dev/null || echo 0)
    HAL_MNT=unknown
    [ -z "$HAL_PID" ] || HAL_MNT=$(readlink "/proc/$HAL_PID/ns/mnt" 2>/dev/null || echo unknown)
    trace "gadget HAL ready pid=$HAL_PID patched_rows=$HAL_ROWS hal_mnt=$HAL_MNT"
    [ "$HAL_ROWS" -gt 0 ] || return 1

    # QTI consults vendor.usb.config only for its ADB-only HIDL branch. A blank
    # data-function request with ADB enabled selects that branch; asking for MTP
    # directly would ignore the vendor composition and silently drop QXR.
    settings put global adb_enabled 1
    setprop vendor.usb.config mtp,qxr,adb
    svc usb setFunctions
    trace "vendor composition requested through ADB branch"
    READY=0
    for i in $(seq 1 100); do
        PID=$(cat /config/usb_gadget/g1/idProduct 2>/dev/null || true)
        LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
        if [ "$PID" = 0xd003 ] && echo "$LINKS" | grep -q ffs.mtp && echo "$LINKS" | grep -q ffs.qxr && echo "$LINKS" | grep -q ffs.adb; then READY=1; break; fi
        sleep 0.1
    done
    trace "composition result ready=$READY pid=$PID"
    [ "$READY" = 1 ]
}

scheme_restore() {
    SAVED_ADB=$(cat "$RUN/adb")
    SAVED_FUNCTIONS=$(cat "$RUN/functions")
    setprop persist.vendor.usb.config.extra "$(cat "$RUN/extra")"
    setprop vendor.usb.config none
    svc usb setFunctions >/dev/null 2>&1 || true
    # Wait until the temporary QXR link is actually gone before removing the
    # patched composition table. This is normally faster than the old fixed 1 s.
    for i in $(seq 1 30); do
        LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
        echo "$LINKS" | grep -q ffs.qxr || break
        sleep 0.1
    done
    umount "$CONF" 2>/dev/null || true
    rm -rf "$MOUNT_STAGE"
    setprop vendor.usb.config "$(cat "$RUN/vendor-config")"
    DATA_FUNCTIONS=$(echo "$SAVED_FUNCTIONS" | sed 's/,adb//;s/adb,//;s/^adb$//;s/^none$//')
    settings put global adb_enabled "$SAVED_ADB"
    svc usb setFunctions "$DATA_FUNCTIONS" >/dev/null 2>&1 || true
    if [ "$SAVED_ADB" = 1 ]; then setprop ctl.start adbd; else setprop ctl.stop adbd; fi
    # Return as soon as the restored standard composition is stable. A fixed
    # four-second delay kept both unknown and known computers waiting after the
    # phone had already restored its USB functions.
    wait_standard_composition "$DATA_FUNCTIONS" "$SAVED_ADB" 50 || true
}

scheme_before_global() {
    [ "$ACTION" = start ] || return 0
        settings put global adb_enabled 1
        # Do not ask UsbDeviceManager to reconfigure an already working MTP
        # composition. Its delayed HAL request can otherwise overwrite D003.
        case ",$OUTER_FUNCTIONS," in
          *,mtp,*) ;;
          *) svc usb setFunctions mtp; sleep 1 ;;
        esac
}
