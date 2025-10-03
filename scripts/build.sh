#!/usr/bin/env bash
# QEMU-Labs 构建脚本：只负责 west build，不再重复 bootstrap 中的初始化逻辑
# version: 2025-10-03-slim-build
set -Eeuo pipefail

BOARD="qemu_cortex_a53"
TRANSPORT="serial"
BUILD_DIR="build"

usage() {
  cat <<'EOF'
用法: ./scripts/build.sh [-b <board>] [-t <serial|udp>] [-o <build_dir>]
  -b    Zephyr 板卡名，默认 qemu_cortex_a53
  -t    传输方式：serial (默认) 或 udp
  -o    构建输出目录，默认 build
示例：./scripts/build.sh -b qemu_cortex_a53 -t udp
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) BOARD="$2"; shift 2 ;;
    -t) TRANSPORT="$2"; shift 2 ;;
    -o) BUILD_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ZEPHYR_BASE="${ROOT}/zephyr"
APP_PATH_FILE="${ROOT}/labs/mcuboot/app_path.txt"

command -v west >/dev/null 2>&1 || { echo "[X] 未找到 west，请先运行 scripts/bootstrap_all.sh" >&2; exit 1; }
[[ -f "${APP_PATH_FILE}" ]] || { echo "[X] 缺少 ${APP_PATH_FILE}" >&2; exit 1; }
APP_PATH="$(<"${APP_PATH_FILE}")"

if [[ -z "${APP_PATH}" ]]; then
  echo "[X] ${APP_PATH_FILE} 为空，请填入 Zephyr 应用路径" >&2
  exit 1
fi

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
  serial)
    EXTRA_CONF="${OVERLAY_SERIAL}"
    ;;
  udp)
    EXTRA_CONF="${OVERLAY_UDP}"
    ;;
  *)
    echo "[X] 不支持的传输方式: ${TRANSPORT} (仅支持 serial|udp)" >&2
    exit 1
    ;;
esac
[[ -f "${EXTRA_CONF}" ]] || { echo "[X] overlay 文件缺失: ${EXTRA_CONF}" >&2; exit 1; }

cat <<EOF
[*] 构建信息：
    board      = ${BOARD}
    transport  = ${TRANSPORT}
    app        = ${APP_ABS}
    build_dir  = ${BUILD_DIR}
EOF

west build \
  -b "${BOARD}" \
  --sysbuild "${APP_ABS}" \
  -d "${BUILD_DIR}" \
  -- \
  -DCONFIG_BOOTLOADER_MCUBOOT=y \
  -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
  -DEXTRA_CONF_FILE="${EXTRA_CONF}"

if [[ -f "${ROOT}/labs/mcuboot/app.version" ]]; then
  printf '[*] app.version = %s\n' "$(<"${ROOT}/labs/mcuboot/app.version")"
fi

printf '[+] 构建完成，主要产物：\n'
printf '    - %s/zephyr/zephyr.bin\n' "${BUILD_DIR}"
printf '    - %s/zephyr/zephyr.signed.bin\n' "${BUILD_DIR}"
printf '    - %s/mcuboot/zephyr/zephyr.bin\n' "${BUILD_DIR}"

