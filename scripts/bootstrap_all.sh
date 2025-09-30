#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（Linux/WSL2）
# 作用：
#  - 安装系统依赖（编译/解压/工具）
#  - 创建并启用本地 Python venv
#  - 安装 west + 扩展依赖（semver, patool 等）
#  - 初始化 Zephyr 工作区并只装 ARM/AArch64 工具链
#  - 安装 mcumgr CLI（Go 版）
#  - 构建演示：qemu_cortex_a53 + MCUboot + smp_svr（串口传输）
# 使用：bash scripts/bootstrap_all.sh
set -euo pipefail

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# 0) 基础检查
cd "$ROOT"
test -f west.yml || { red "[X] 未找到 west.yml，请在 qemu-labs 仓库根目录执行。"; exit 2; }

cyan "[1/8] 安装系统依赖（需要 sudo）"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential

cyan "[2/8] 创建并启用本地 Python 虚拟环境 .venv"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

cyan "[3/8] 安装 west 及扩展依赖（确保与 west 同解释器）"
python -m pip install -U west semver patool requests tqdm pyyaml colorama psutil

cyan "[4/8] 初始化 Zephyr 工作区"
west init -l .
west update
west zephyr-export

cyan "[5/8] 安装 Zephyr SDK（仅 ARM/AArch64 工具链）"
# 尝试只装 ARM 目标，避免 Xtensa
if ! west sdk install -t aarch64-zephyr-elf -t arm-zephyr-eabi; then
  yellow "[!] west sdk install 失败，尝试调用 SDK 安装脚本（若已有 SDK）。"
  if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && [ -x "$ZEPHYR_SDK_INSTALL_DIR/setup.sh" ]; then
    "$ZEPHYR_SDK_INSTALL_DIR/setup.sh" -t aarch64-zephyr-elf -t arm-zephyr-eabi
  else
    red "[X] 未能安装 SDK。可重试：west sdk install -t aarch64-zephyr-elf -t arm-zephyr-eabi"
    exit 3
  fi
fi

cyan "[6/8] 安装 mcumgr CLI（Go 版）"
# GOPATH 默认在 ~/go，确保 PATH 中包含
go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
if ! command -v mcumgr >/dev/null 2>&1; then
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
fi

cyan "[7/8] 构建演示：MCUboot + smp_svr（板卡：qemu_cortex_a53，传输：serial）"
./scripts/build.sh -b qemu_cortex_a53 -t serial

cyan "[8/8] 启动示例（QEMU，无头串口），随后按提示设置 mcumgr 串口"
./scripts/run.sh || true

cat <<'MSG'

============================================================
[下一步：用 mcumgr 连接（串口模式）]
1) 在上一步 QEMU 日志中找到伪终端：类似 /dev/pts/N
2) 在新终端执行：
   source .venv/bin/activate
   export SERIAL_DEV=/dev/pts/<N>     # 替换 <N>
   ./scripts/mcumgr.sh serial-list    # 查看镜像
   # 升级流程（示例）：
   ./scripts/mcumgr.sh serial-upload
   ./scripts/mcumgr.sh serial-test <hash>
   ./scripts/mcumgr.sh serial-reset
   ./scripts/mcumgr.sh serial-confirm

[可选：环境自检（会编译 hello_world 并运行）]
   ./scripts/check_sdk.sh

提示：
- 如果你不是 WSL2、而是原生 Linux，并且想用 UDP 传输：
  先不要运行 run.sh，改走：
    ./scripts/net_up.sh     # 开 TAP/bridge
    ./scripts/build.sh -b qemu_cortex_a53 -t udp
    ./scripts/run.sh
  然后：
    ./scripts/mcumgr.sh list
  结束后：
    ./scripts/net_down.sh

- 将 .venv 激活写入 shell 启动脚本（可选）：
    echo 'source $PWD/.venv/bin/activate' >> ~/.zshrc   # zsh
    # 或者：
    echo 'source $PWD/.venv/bin/activate' >> ~/.bashrc  # bash
============================================================
MSG

green "全部完成 🎉  若有报错，把完整输出贴给我，我按步骤帮你定位。"
