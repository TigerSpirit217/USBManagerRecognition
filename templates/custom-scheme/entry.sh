#!/system/bin/sh
set -eu
ACTION=${1:?Missing action}
STATE_DIR=${2:?Missing state directory}
ABI=${3:?Missing ABI}
APP_PROCESS=${4:?Missing Android runtime}
MODE_OR_ID=${5:-closed}
PROFILE=${6:-none}
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Implement your own transport, authentication and matching Windows program.
# Never report support until your real local device check succeeds.
case "$ACTION" in
  detect) echo 'USBMGR_SUPPORTED 0'; exit 3 ;;
  start) echo 'AUTH_RESULT TIMEOUT'; exit 0 ;;
  restore)
    # This empty template has no active interface. Your real implementation must
    # stop its daemon and restore every temporary USB change, even after failure.
    echo USBMGR_RESTORED
    ;;
  list) : ;;
  edit|delete) echo 'Not implemented' >&2; exit 3 ;;
  *) echo 'Unknown action' >&2; exit 2 ;;
esac
