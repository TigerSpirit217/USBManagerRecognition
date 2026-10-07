#!/system/bin/sh
CONF=/vendor/etc/usb_compositions.conf
for CANDIDATE in /odm/etc/usb_compositions.conf /product/etc/usb_compositions.conf /vendor/etc/usb_compositions.conf; do
    [ -r "$CANDIDATE" ] && grep -q '^qxr,adb[[:space:]]' "$CANDIDATE" 2>/dev/null || continue
    CONF=$CANDIDATE
    break
done
scheme_prepare() {
    # Vendor-managed Qualcomm gadgets are deliberately excluded: a virtual-only
    # ConfigFS pass would over-report support on devices whose physical UDC rejects
    # direct gadget takeover (as observed on Nothing A065).
    if [ -e "$CONF" ] && grep -q '^qxr,adb[[:space:]]' "$CONF" 2>/dev/null; then
        return 1
    fi
    G=/config/usb_gadget/g1
    [ -d "$G/functions" ] && [ -d "$G/configs" ] || return 1
    C=$(find "$G/configs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [ -n "$C" ] || return 1
    UDC=$(cat "$G/UDC" 2>/dev/null || true)
    [ -n "$UDC" ] || return 1
    [ -d "/sys/class/udc/$UDC" ] || return 1
    F=/dev/usb-ffs/usb_auth
    FN=$G/functions/ffs.usb_auth
    LINK=$C/usbmanager_auth
    [ ! -e "$FN" ] && [ ! -L "$LINK" ] || return 1
    mountpoint -q "$F" && return 1
    echo "$UDC" > "$RUN/generic.udc"
    echo "$LINK" > "$RUN/generic.link"
    touch "$RUN/generic"
    mkdir -p "$F" || return 1
    touch "$RUN/generic.mount"
    mount -t functionfs usb_auth "$F" || return 1
    daemon_start "$F" "$MODE" "$RUN/daemon.log" "$RUN/auth-result" || return 1
    echo "$DAEMON" > "$RUN/daemon.pid"
    touch "$RUN/generic.detached"
    echo '' > "$G/UDC"
    touch "$RUN/generic.function"
    mkdir "$FN"
    touch "$RUN/generic.linked"
    ln -s "$FN" "$LINK"
    echo "$UDC" > "$G/UDC"
    for i in $(seq 1 30); do
        [ "$(cat "$G/UDC" 2>/dev/null || true)" = "$UDC" ] && return 0
        sleep 0.1
    done
    return 1
}

scheme_probe() {
    # Classify Qualcomm/QXR gadgets before creating state or touching the active
    # USB configuration. Their supported path is the read-only Nothing probe.
    if [ -e "$CONF" ] && grep -q '^qxr,adb[[:space:]]' "$CONF" 2>/dev/null; then
        return 1
    fi
    rm -rf "$RUN"; save_state || return 1
    trap 'restore; release_operation' EXIT
    arm_watchdog
    RESULT=0
    scheme_prepare || RESULT=$?
    restore
    trap 'release_operation' EXIT
    return "$RESULT"
}

scheme_restore() {
        [ -f "$RUN/generic" ] || return 0
        G=/config/usb_gadget/g1
        UDC=$(cat "$RUN/generic.udc")
        LINK=$(cat "$RUN/generic.link")
        [ ! -f "$RUN/generic.detached" ] || echo '' > "$G/UDC" 2>/dev/null || true
        [ ! -f "$RUN/generic.linked" ] || rm -f "$LINK"
        [ ! -f "$RUN/generic.function" ] || rmdir "$G/functions/ffs.usb_auth" 2>/dev/null || true
        [ ! -f "$RUN/generic.detached" ] || echo "$UDC" > "$G/UDC" 2>/dev/null || true
        [ ! -f "$RUN/generic.mount" ] || umount /dev/usb-ffs/usb_auth 2>/dev/null || true
        rmdir /dev/usb-ffs/usb_auth 2>/dev/null || true
}

scheme_before_global() { :; }
