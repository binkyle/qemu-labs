#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（把所有模块与 SDK 安装到当前仓库内）
set -euo pipefail

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(basename "$ROOT")"                 # e.g. qemu-labs
TOPDIR_PARENT="$(cd "$ROOT/.." && pwd)"    # workspace topdir（父目录）
cd "$ROOT"
test -f west.yml || { red "[X] 未找到 west.yml，请在 $REPO 根目录执行"; exit 2; }

# 全部落库：SDK & 工具
export ZEPHYR_SDK_INSTALL_DIR="$ROOT/.zephyr-sdk"
export GOBIN="$ROOT/tools/bin"
mkdir -p "$GOBIN"

cyan "[1/8] 系统依赖"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential

cyan "[2/8] Python venv（$REPO/.venv）"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

cyan "[3/8] 安装 west + 扩展依赖（semver/patool 等）"
python -m pip install -U west semver patool requests tqdm pyyaml colorama psutil

cyan "[4/8] 以父目录作为 workspace topdir 初始化（模块全部克隆到 $REPO/ 内）"
# 备份旧 west.yml 并重写一个“路径固定到仓库”的 manifest
cp -a west.yml "west.yml.bak.$(date +%s)" || true
cat > west.yml <<EOF
manifest:
  version: 0.13
  defaults:
    remote: zephyrproject-rtos
  remotes:
    - name: zephyrproject-rtos
      url-base: https://github.com/zephyrproject-rtos
  projects:
    - name: zephyr
      revision: main
      path: ${REPO}/zephyr            # <== 把 zephyr 放到 仓库内
      import:
        path-prefix: ${REPO}          # <== 所有 imported 模块也前缀到 仓库内
  self:
    path: ${REPO}                      # <== manifest 仓库在 topdir/${REPO}
EOF

# 清理历史 workspace 标记，并在父目录创建新的 workspace
[ -d "$TOPDIR_PARENT/.west" ] && mv "$TOPDIR_PARENT/.west" "$TOPDIR_PARENT/.west.bak.$(date +%s)" || true
rm -rf .west

# 注意这里用 ".."：workspace topdir = 父目录；模块都会按上面 path-prefix 克隆到 $REPO/ 下
west init -l ..
west update
west zephyr-export

# 基础校验
test -d "$TOPDIR_PARENT/$REPO/zephyr" || { red "[X] 未找到 $REPO/zephyr（west update 失败？）"; exit 3; }
cyan "    workspace topdir: $(west topdir)"
cyan "    ZEPHYR_BASE 应在: $TOPDIR_PARENT/$REPO/zephyr"

cyan "[5/8] 安装 Zephyr SDK（仅 ARM/AArch64，安装到 $ZEPHYR_SDK_INSTALL_DIR）"
west sdk install -t aarch64-zephyr-elf -t arm-zephyr-eabi || {
  yellow "[!] west sdk install 失败，若已手动下载安装器到 $ZEPHYR_SDK_INSTALL_DIR，请执行："
  echo    "    \"$ZEPHYR_SDK_INSTALL_DIR/setup.sh\" -t aarch64-zephyr-elf -t arm-zephyr-eabi"
  exit 4
}

cyan "[6/8] 安装 mcumgr 到 $GOBIN"
go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
export PATH="$GOBIN:$PATH"

cyan "[7/8] 构建演示：qemu_cortex_a53 + MCUboot + smp_svr（串口）"
./scripts/build.sh -b qemu_cortex_a53 -t serial

cyan "[8/8] 运行（QEMU 串口）"
./scripts/run.sh || true

cat <<'MSG'

============================================================
下一步（串口模式）：
1) 在 QEMU 输出中找到 /dev/pts/<N>
2) 新终端：
   source .venv/bin/activate
   export PATH="$(pwd)/tools/bin:$PATH"
   export SERIAL_DEV=/dev/pts/<N>
   ./scripts/mcumgr.sh serial-list

原生 Linux 想用 UDP：
   ./scripts/net_up.sh
   ./scripts/build.sh -b qemu_cortex_a53 -t udp
   ./scripts/run.sh
   ./scripts/mcumgr.sh list
   ./scripts/net_down.sh

环境自检（会编译运行 hello_world）：
   ./scripts/check_sdk.sh
============================================================
MSG

green "全部完成 ✅"
