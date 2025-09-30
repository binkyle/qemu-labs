#!/usr/bin/env bash
set -euo pipefail

BOARD="qemu_cortex_a53"   # 默认 ARM64
TRANSPORT="serial"        # serial | udp
BUILD_DIR="build"

while getopts "b:t:o:" opt; do
  case $opt in
    b) BOARD="$OPTARG" ;;
    t) TRANSPORT="$OPTARG" ;;
    o) BUILD_DIR="$OPTARG" ;;
    *) echo "Usage: $0 -b <board> -t <serial|udp> [-o build_dir]"; exit 1 ;;
  esac
done

TOP="$(git rev-parse --show_toplevel 2>/dev/null || git rev-parse --show-toplevel)"
WEST_TOPDIR="$(west topdir)"
ZEPHYR_BASE="${WEST_TOPDIR}/zephyr"

APP_PATH_FILE="${TOP}/labs/mcuboot/app_path.txt"
APP_PATH="$(cat "${APP_PATH_FILE}")"

# 相对路径视为 Zephyr 树内路径
if [[ "${APP_PATH}" != /* ]]; then
  APP_ABS="${ZEPHYR_BASE}/${APP_PATH}"
else
  APP_ABS="${APP_PATH}"
fi

OVERLAY_UDP="${ZEPHYR_BASE}/samples/subsys/mgmt/mcumgr/smp_svr/overlay-udp.conf"
OVERLAY_SERIAL="${ZEPHYR_BASE}/samples/subsys/mgmt/mcumgr/smp_svr/overlay-serial.conf"
EXTRA="-DEXTRA_CONF_FILE=${OVERLAY_SERIAL}"
if [ "${TRANSPORT}" = "udp" ]; then
  EXTRA="-DEXTRA_CONF_FILE=${OVERLAY_UDP}"
fi

echo "[*] Building ${APP_ABS} for ${BOARD} (transport=${TRANSPORT}) ..."
if [ ! -d "${APP_ABS}" ]; then
  echo "ERROR: source directory ${APP_ABS} does not exist"
  echo "HINT:"
  echo "  - west topdir = ${WEST_TOPDIR}"
  echo "  - ZEPHYR_BASE = ${ZEPHYR_BASE}"
  echo "  - app_path.txt = ${APP_PATH}"
  exit 2
fi

west build -b "${BOARD}" --sysbuild "${APP_ABS}" -d "${BUILD_DIR}" \
  -- -DCONFIG_BOOTLOADER_MCUBOOT=y -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
     ${EXTRA}

echo "[+] Build done. Artifacts:"
echo "    - ${BUILD_DIR}/zephyr/zephyr.signed.bin"
