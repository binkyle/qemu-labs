#!/usr/bin/env bash
# QEMU-Labs build helper (sysbuild + MCUboot)
# version: 2025-10-04-slim-build
set -euo pipefail

BOARD="qemu_cortex_a53"
TRANSPORT="serial"
BUILD_DIR="build"

usage() {
  cat <<'USAGE'
用法: ./scripts/build.sh [-b <board>] [-t <serial|udp>] [-o <build_dir>]
  -b    Zephyr 板卡名 (默认 qemu_cortex_a53)
  -t    传输方式 serial|udp (默认 serial)
  -o    构建输出目录 (默认 build)
  -h    显示本帮助
USAGE
}

while getopts "b:t:o:h" opt; do
  case "$opt" in
    b) BOARD="$OPTARG" ;;
    t) TRANSPORT="$OPTARG" ;;
    o) BUILD_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ZEPHYR_BASE="${ROOT}/zephyr"
APP_PATH_FILE="${ROOT}/labs/mcuboot/app_path.txt"
PM_STATIC_YML="${ROOT}/labs/mcuboot/pm_static.yml"

command -v west >/dev/null 2>&1 || { echo "[X] 未找到 west，请先运行 scripts/bootstrap_all.sh" >&2; exit 1; }
[[ -f "${APP_PATH_FILE}" ]] || { echo "[X] 缺少 ${APP_PATH_FILE}" >&2; exit 1; }
APP_PATH="$(<"${APP_PATH_FILE}")"
[[ -n "${APP_PATH}" ]] || { echo "[X] ${APP_PATH_FILE} 为空，请填写 Zephyr 应用路径" >&2; exit 1; }

if [[ "${APP_PATH}" != /* ]]; then
  APP_ABS="${ZEPHYR_BASE}/${APP_PATH}"
else
  APP_ABS="${APP_PATH}"
fi
[[ -d "${APP_ABS}" ]] || { echo "[X] 应用目录不存在: ${APP_ABS}" >&2; exit 1; }

OVERLAY_DIR="${ZEPHYR_BASE}/samples/subsys/mgmt/mcumgr/smp_svr"
OVERLAY_SERIAL="${OVERLAY_DIR}/overlay-serial.conf"
OVERLAY_UDP="${OVERLAY_DIR}/overlay-udp.conf"
case "${TRANSPORT}" in
  serial) EXTRA_CONF="${OVERLAY_SERIAL}" ;;
  udp)    EXTRA_CONF="${OVERLAY_UDP}" ;;
  *) echo "[X] 不支持的传输方式: ${TRANSPORT}" >&2; exit 1 ;;
esac
[[ -f "${EXTRA_CONF}" ]] || { echo "[X] overlay 缺失: ${EXTRA_CONF}" >&2; exit 1; }

cmake_extra=()
if [[ -f "${PM_STATIC_YML}" ]]; then
  cmake_extra+=(-DPM_STATIC_YML="${PM_STATIC_YML}")
fi

if ((${#cmake_extra[@]})); then
  west_cmake_extra=("${cmake_extra[@]}")
else
  west_cmake_extra=()
fi

cat <<INFO
[*] 构建信息:
    board      = ${BOARD}
    transport  = ${TRANSPORT}
    app        = ${APP_ABS}
    build_dir  = ${BUILD_DIR}
INFO

west build \
  -b "${BOARD}" \
  --sysbuild "${APP_ABS}" \
  -d "${BUILD_DIR}" \
  "${west_cmake_extra[@]}" \
  -- \
  -DCONFIG_BOOTLOADER_MCUBOOT=y \
  -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
  -DEXTRA_CONF_FILE="${EXTRA_CONF}"

if [[ -f "${ROOT}/labs/mcuboot/app.version" ]]; then
  printf '[*] app.version = %s\n' "$(<"${ROOT}/labs/mcuboot/app.version")"
fi

echo "[+] 构建完成，主要产物:"
echo "    - ${BUILD_DIR}/zephyr/zephyr.bin"
echo "    - ${BUILD_DIR}/zephyr/zephyr.signed.bin"
echo "    - ${BUILD_DIR}/mcuboot/zephyr/zephyr.bin"