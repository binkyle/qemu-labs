#!/usr/bin/env bash
# QEMU-Labs �����ű���ֻ���� west build�������ظ� bootstrap �еĳ�ʼ���߼�
# version: 2025-10-03-slim-build
set -Eeuo pipefail

BOARD="qemu_cortex_a53"
TRANSPORT="serial"
BUILD_DIR="build"

usage() {
  cat <<'EOF'
�÷�: ./scripts/build.sh [-b <board>] [-t <serial|udp>] [-o <build_dir>]
  -b    Zephyr �忨����Ĭ�� qemu_cortex_a53
  -t    ���䷽ʽ��serial (Ĭ��) �� udp
  -o    �������Ŀ¼��Ĭ�� build
ʾ����./scripts/build.sh -b qemu_cortex_a53 -t udp
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) BOARD="$2"; shift 2 ;;
    -t) TRANSPORT="$2"; shift 2 ;;
    -o) BUILD_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "δ֪����: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ZEPHYR_BASE="${ROOT}/zephyr"
APP_PATH_FILE="${ROOT}/labs/mcuboot/app_path.txt"

command -v west >/dev/null 2>&1 || { echo "[X] δ�ҵ� west���������� scripts/bootstrap_all.sh" >&2; exit 1; }
[[ -f "${APP_PATH_FILE}" ]] || { echo "[X] ȱ�� ${APP_PATH_FILE}" >&2; exit 1; }
APP_PATH="$(<"${APP_PATH_FILE}")"

if [[ -z "${APP_PATH}" ]]; then
  echo "[X] ${APP_PATH_FILE} Ϊ�գ������� Zephyr Ӧ��·��" >&2
  exit 1
fi

if [[ "${APP_PATH}" != /* ]]; then
  APP_ABS="${ZEPHYR_BASE}/${APP_PATH}"
else
  APP_ABS="${APP_PATH}"
fi
[[ -d "${APP_ABS}" ]] || { echo "[X] Ӧ��Ŀ¼������: ${APP_ABS}" >&2; exit 1; }

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
    echo "[X] ��֧�ֵĴ��䷽ʽ: ${TRANSPORT} (��֧�� serial|udp)" >&2
    exit 1
    ;;
esac
[[ -f "${EXTRA_CONF}" ]] || { echo "[X] overlay �ļ�ȱʧ: ${EXTRA_CONF}" >&2; exit 1; }

cat <<EOF
[*] ������Ϣ��
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

printf '[+] ������ɣ���Ҫ���\n'
printf '    - %s/zephyr/zephyr.bin\n' "${BUILD_DIR}"
printf '    - %s/zephyr/zephyr.signed.bin\n' "${BUILD_DIR}"
printf '    - %s/mcuboot/zephyr/zephyr.bin\n' "${BUILD_DIR}"

