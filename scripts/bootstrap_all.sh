#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（全部安装到仓库内）
set -euo pipefail

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
test -f west.yml || { red "[X] 未找到 west.yml，请在 qemu-labs 根目录执行"; exit 2; }

# -------- 安装目录策略（全部落在仓库内） --------
export ZEPHYR_SDK_INSTALL_DIR="$ROOT/.zephyr-sdk"   # SDK 安装在 qemu-labs/.zephyr-sdk
export GOBIN="$ROOT/tools/bin"                      # mcumgr 安装到 qemu-labs/tools/bin
mkdir -p "$GOBIN"

cyan "[1/8] 系统依赖"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential

cyan "[2/8] Python venv（仓库内 .venv）"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

cyan "[3/8] 安装 west + 扩展依赖（semver/patool 等）"
python -m pip install -U west semver patool requests tqdm pyyaml colorama psutil

cyan "[4/8] 以当前仓库为 workspace 重新初始化（确保模块装在仓库内）"
# 修正 self.path 为当前目录
sed -i 's|^\(\s*path:\s*\).*|\1.|' west.yml
# 若父目录存在历史 .west，备份后清掉
[ -d ../.west ] && mv ../.west ../.west.bak_$(date +%s) || true
rm -rf .west
# 关键修复：只有一个点
west init -l .
west update
west zephyr-export

# 验证 workspace 根目录
TOPDIR="$(west topdir)"
if [ "$TOPDIR" != "$ROOT" ]; then
  red "[X] workspace 根目录不是 qemu-labs：$TOPDIR"
  echo "    期望：$ROOT"
  exit 3
fi
test -d zephyr || { red "[X] 未找到 $ROOT/zephyr（west update 是否成功？）"; exit 3; }

cyan "[5/8] 安装 Zephyr SDK（仅 ARM/AArch64，安装到 $ZEPHYR_SDK_INSTALL_DIR）"
west sdk install -t aarch64-zephyr-elf -t arm-zephyr-eabi || {
  yellow "[!] west sdk install 失败，尝试直接调用 setup.sh（若安装器已在该目录）"
  if [ -x "$ZEPHYR_SDK_INSTALL_DIR/setup.sh" ]; then
    "$ZEPHYR_SDK_INSTALL_DIR/setup.sh" -t aarch64-zephyr-elf -t arm-zephyr-eabi
  else
    red "[X] SDK 安装失败，请检查网络或手动下载 .run 到 $ZEPHYR_SDK_INSTALL_DIR 再执行 setup.sh"
    exit 4
  fi
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

若是原生 Linux 想用 UDP：
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
