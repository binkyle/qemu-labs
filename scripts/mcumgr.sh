
#!/usr/bin/env bash
set -euo pipefail

# 默认 UDP（Zephyr net-tools 典型配置）
UDP_ADDR=${UDP_ADDR:-"192.0.2.2"}
UDP_PORT=${UDP_PORT:-"1337"}

# 串口模式：请把 SERIAL_DEV 改成实际的 /dev/pts/N
SERIAL_DEV=${SERIAL_DEV:-"/dev/pts/1"}
SERIAL_BAUD=${SERIAL_BAUD:-"115200"}

MODE=${1:-list}

mcumgr_udp() {
  mcumgr --conntype udp --connstring "addr=${UDP_ADDR},port=${UDP_PORT}" "$@"
}
mcumgr_serial() {
  mcumgr --conntype serial --connstring "dev=${SERIAL_DEV},baud=${SERIAL_BAUD}" "$@"
}

case "$MODE" in
  list)       mcumgr_udp image list ;;
  upload)     BIN="build/zephyr/zephyr.signed.bin"; [ -f "$BIN" ] || { echo "Not found: $BIN"; exit 1; }; mcumgr_udp image upload -e "$BIN" ;;
  test)       HASH=${2:-""}; [ -n "$HASH" ] || { echo "Usage: $0 test <image-hash>"; exit 1; }; mcumgr_udp image test "$HASH" ;;
  confirm)    mcumgr_udp image confirm ;;
  reset)      mcumgr_udp reset ;;
  serial-list)    mcumgr_serial image list ;;
  serial-upload)  mcumgr_serial image upload -e build/zephyr/zephyr.signed.bin ;;
  serial-test)    mcumgr_serial image test "${2:?hash required}" ;;
  serial-confirm) mcumgr_serial image confirm ;;
  serial-reset)   mcumgr_serial reset ;;
  *)
    echo "Usage: $0 {list|upload|test <hash>|confirm|reset|serial-*}"
    exit 1
    ;;
esac
