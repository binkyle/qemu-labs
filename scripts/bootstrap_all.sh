#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（全部安装在仓库内）
#  - west topdir = 仓库根（qemu-labs）
#  - zephyr / 模块 -> qemu-labs/zephyr/...
#  - Zephyr SDK   -> qemu-labs/.zephyr-sdk
#  - mcumgr       -> qemu-labs/tools/bin
#  - 构建并运行：qemu_cortex_a53 + MCUboot + smp_svr（串口模式）

set -euo pipefail

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

# --- 0) 基本路径与目标 ---
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPO_NAME="$(basename "$ROOT")"              # 一般为 qemu-labs
export ZEPHYR_SDK_INSTALL_DIR="$ROOT/.zephyr-sdk"
export GOBIN="$ROOT/tools/bin"
mkdir -p "$GOBIN"
ZEPHYR_REMOTE_URL_BASE="${ZEPHYR_REMOTE_URL_BASE:-https://github.com/zephyrproject-rtos}"
# Allow overriding the Zephyr remote base when GitHub is blocked

test -f west.yml || {
  red "[X] 未找到 west.yml，请在仓库根执行。当前目录: $ROOT"
  exit 2
}

cyan "[1/8] 安装系统依赖（需要 sudo）"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential

cyan "[2/8] 创建本地 Python 虚拟环境（$REPO_NAME/.venv）"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

cyan "[3/8] 安装 west 与扩展依赖（确保与 west 同解释器）"
python -m pip install -U west semver patool requests tqdm pyyaml colorama psutil
hash -r 2>/dev/null || true

cyan "[4/8] 以“仓库根”为 west workspace 重新初始化（模块安装在仓库内）"
# 4.1 清理可能影响定位的上层 .west
if [ -d ../.west ]; then
  mv ../.west "../.west.bak.$(date +%s)" || true
fi
rm -rf .west

# 4.2 备份并写入一个“最小可用 + 路径固定”的 west.yml
cp -a west.yml "west.yml.bak.$(date +%s)" || true
yellow "    west remote base: $ZEPHYR_REMOTE_URL_BASE"
cat > west.yml <<EOF
manifest:
  version: 0.13
  remotes:
    - name: zephyrproject-rtos
      url-base: ${ZEPHYR_REMOTE_URL_BASE}
  defaults:
    remote: zephyrproject-rtos
  projects:
    - name: zephyr
      revision: main           # 稳定可改 v3.6.0 等
      path: zephyr             # => qemu-labs/zephyr
      import: true             # 其余模块也落到 qemu-labs/ 下
  self:
    path: .                    # 关键：让 west topdir == 仓库根
EOF

# 4.3 初始化并拉取
west init -l .
west update
west zephyr-export

# 4.4 校验 topdir 与 zephyr 目录
TOPDIR="$(west topdir)"
if [ "$TOPDIR" != "$ROOT" ]; then
  red "[X] west topdir ($TOPDIR) 不是仓库根 ($ROOT)。"
  echo "    请确认父目录没有干扰性的 .west，或重新执行本脚本。"
  exit 3
fi
test -d "$ROOT/zephyr" || {
  red "[X] 未找到 $ROOT/zephyr，west update 是否成功？"
  exit 3
}
cyan "    workspace topdir: $TOPDIR"
cyan "    zephyr base     : $ROOT/zephyr"

cyan "[5/8] 安装 Zephyr SDK（仅 ARM/AArch64 工具链，安装到 $ZEPHYR_SDK_INSTALL_DIR）"
if ! west sdk install -t aarch64-zephyr-elf -t arm-zephyr-eabi; then
  yellow "[!] west sdk install 失败。若你已手动下载 SDK 安装器到 $ZEPHYR_SDK_INSTALL_DIR："
  echo    "    \"$ZEPHYR_SDK_INSTALL_DIR/setup.sh\" -t aarch64-zephyr-elf -t arm-zephyr-eabi"
  exit 4
fi

cyan "[6/8] 安装 mcumgr 到 $GOBIN 并加入 PATH"
go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
export PATH="$GOBIN:$PATH"

cyan "[7/8] 构建演示（qemu_cortex_a53 + MCUboot + smp_svr，串口模式）"

# 优先使用项目自带 build.sh；若不存在/失败，则兜底直接 west build
BUILD_OK=0
if [ -x ./scripts/build.sh ]; then
  if ./scripts/build.sh -b qemu_cortex_a53 -t serial; then
    BUILD_OK=1
  fi
fi

if [ "$BUILD_OK" -eq 0 ]; then
  yellow "[!] 未找到或调用 scripts/build.sh 失败，使用兜底构建路径"
  APP_ABS="$ROOT/zephyr/samples/subsys/mgmt/mcumgr/smp_svr"
  OVERLAY_SERIAL="$ROOT/zephyr/samples/subsys/mgmt/mcumgr/smp_svr/overlay-serial.conf"
  if [ ! -d "$APP_ABS" ]; then
    red "[X] 兜底路径不存在：$APP_ABS"
    echo "    请确认 west update 成功，或手动检查权限/网络。"
    exit 5
  fi
  west build -b qemu_cortex_a53 --sysbuild "$APP_ABS" -d build \
    -- -DCONFIG_BOOTLOADER_MCUBOOT=y -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
       -DEXTRA_CONF_FILE="$OVERLAY_SERIAL"
fi

cyan "[8/8] 启动（QEMU 串口）。若失败不会中断，下面有下一步提示。"
if [ -x ./scripts/run.sh ]; then
  ./scripts/run.sh || true
else
  west build -d build -t run || true
fi

cat <<'MSG'

============================================================
下一步（串口模式）：
1) 在 QEMU 输出中找到分配的伪终端：/dev/pts/<N>
2) 新终端执行：
   source .venv/bin/activate
   export PATH="$(pwd)/tools/bin:$PATH"
   export SERIAL_DEV=/dev/pts/<N>
   ./scripts/mcumgr.sh serial-list

升级流程（示例）：
   ./scripts/mcumgr.sh serial-upload
   ./scripts/mcumgr.sh serial-test <hash>
   ./scripts/mcumgr.sh serial-reset
   ./scripts/mcumgr.sh serial-confirm

提示：
- WSL2 环境请坚持串口模式；原生 Linux 若要 UDP：
   ./scripts/net_up.sh
   ./scripts/build.sh -b qemu_cortex_a53 -t udp
   ./scripts/run.sh
   ./scripts/mcumgr.sh list
   ./scripts/net_down.sh

- SDK/工具链自检：
   ./scripts/check_sdk.sh

============================================================
MSG

green "全部完成 ✅  若仍有路径问题，请把以下输出发我："
echo "  west topdir => $TOPDIR"
echo "  ZEPHYR_BASE => $ROOT/zephyr"
