
#!/usr/bin/env bash
set -euo pipefail

BOARD="qemu_cortex_a53"   # ARM 默认
TRANSPORT="udp"           # udp | serial
BUILD_DIR="build"

while getopts "b:t:o:" opt; do
  case $opt in
    b) BOARD="$OPTARG" ;;
    t) TRANSPORT="$OPTARG" ;;
    o) BUILD_DIR="$OPTARG" ;;
    *) echo "Usage: $0 -b <board> -t <udp|serial> [-o build_dir]"; exit 1 ;;
  esac
done

TOP="$(git rev-parse --show-toplevel)"
ZEPHYR_BASE="${TOP}/zephyr"
APP_PATH_FILE="${TOP}/labs/mcuboot/app_path.txt"
APP_PATH="$(cat "${APP_PATH_FILE}")"

# 解析应用绝对路径（相对路径认为在 Zephyr 树内）
if [[ "${APP_PATH}" != /* ]]; then
  APP_ABS="${ZEPHYR_BASE}/${APP_PATH}"
else
  APP_ABS="${APP_PATH}"
fi

# 选择 overlay（默认用 Zephyr 自带的）
OVERLAY_UDP="${ZEPHYR_BASE}/samples/subsys/mgmt/mcumgr/smp_svr/overlay-udp.conf"
OVERLAY_SERIAL="${ZEPHYR_BASE}/samples/subsys/mgmt/mcumgr/smp_svr/overlay-serial.conf"

EXTRA="-DEXTRA_CONF_FILE=${OVERLAY_UDP}"
if [ "${TRANSPORT}" = "serial" ]; then
  EXTRA="-DEXTRA_CONF_FILE=${OVERLAY_SERIAL}"
fi

echo "[*] Building ${APP_ABS} for ${BOARD} (transport=${TRANSPORT}) ..."
west build -b "${BOARD}" --sysbuild "${APP_ABS}" -d "${BUILD_DIR}"       -- -DCONFIG_BOOTLOADER_MCUBOOT=y -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y          ${EXTRA}

if [ -f "${TOP}/labs/mcuboot/app.version" ]; then
  VER="$(cat "${TOP}/labs/mcuboot/app.version")"
  echo "[*] App version hint: ${VER}"
fi

echo "[+] Build done. Artifacts:"
echo "    - ${BUILD_DIR}/zephyr/zephyr.bin           (app)"
echo "    - ${BUILD_DIR}/zephyr/zephyr.signed.bin    (signed app for MCUboot)"
echo "    - ${BUILD_DIR}/mcuboot/zephyr/zephyr.bin   (mcuboot image)"
