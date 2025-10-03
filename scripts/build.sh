#!/usr/bin/env bash
# QEMU-Labs 统一构建脚本（不会把 west 放到父目录）
# version: 2025-10-03-fix-build-topdir
set -Eeuo
if set -o 2>/dev/null | grep -q 'pipefail'; then set -o pipefail; fi

# ---- 简易日志 ----
RESET='\033[0m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
log()  { printf "${CYAN}%s${RESET}\n" "$*"; }
ok()   { printf "${GREEN}%s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}%s${RESET}\n" "$*"; }
err()  { printf "${RED}%s${RESET}\n" "$*"; }

# ---- 路径 ----
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(basename "$ROOT")"
cd "$ROOT"
[[ -f west.yml ]] || { err "[X] 未找到 west.yml；请在仓库根运行。当前: $ROOT"; exit 2; }

# 统一安装到仓库内（若系统已装 SDK，会被 west 复用；可改成强制仓库内，见注释）
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$ROOT/.zephyr-sdk}"
export GOBIN="$ROOT/tools/bin"; mkdir -p "$GOBIN"

# ---- [1/8] 系统依赖 ----
log "[1/8] 系统依赖"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential
git config --global core.autocrlf input || true
git config --global fetch.prune true || true

# ---- [2/8] Python venv ----
log "[2/8] Python venv（$REPO/.venv）"
[[ -d .venv ]] || python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install -U pip setuptools wheel

# ---- [3/8] west + 依赖 ----
log "[3/8] 安装 west + 扩展依赖（semver/patool 等）"
python3 -m pip install -U west semver patool requests tqdm pyyaml colorama psutil

# ---- [4/8] 锁定 workspace 到仓库根（不去父目录） ----
log "[4/8] 锁定 workspace 到仓库根（模块全部克隆到 $REPO/ 内）"

# 4.1 预置 .west/config：把工作区“钉”在当前仓库
mkdir -p .west
cat > .west/config <<'CONF'
[manifest]
path = .
file = west.yml
CONF

# 4.2 写最小 manifest（保证 self.path = .；模块都在仓库内）
cp -a west.yml "west.yml.bak.$(date +%s)" 2>/dev/null || true
cat > west.yml <<'EOF'
manifest:
  version: 0.13
  remotes:
    - name: zephyrproject-rtos
      url-base: https://github.com/zephyrproject-rtos
  defaults:
    remote: zephyrproject-rtos
  projects:
    - name: zephyr
      revision: main
      path: zephyr
      import: true
  self:
    path: .
EOF

# 4.3 仅在“尚未初始化”时才 init（避免 already initialized 噪音）
if [[ ! -f .west/manifest ]]; then
  west init -l .
fi

# 4.4 修正配置并拉取；校验 topdir 必须是仓库根
west config manifest.path .
west config manifest.file west.yml
west update
td="$(west topdir 2>/dev/null || true)"
if [[ "$td" != "$ROOT" ]]; then
  err "[X] west topdir=$td 仍不是仓库根=$ROOT；请执行：rm -rf ../.west .west；然后重跑 ./build.sh"
  exit 3
fi
[[ -d "$ROOT/zephyr" ]] || { err "[X] 未找到 $ROOT/zephyr；west update 失败？"; exit 3; }
ok "   -> workspace OK：$td"

# ---- [5/8] 安装 Zephyr SDK（仅 ARM/AArch64） ----
log "[5/8] 安装 Zephyr SDK（仅 ARM/AArch64，安装到 $ZEPHYR_SDK_INSTALL_DIR 或复用系统已有）"
missing=()
[[ -x "$ZEPHYR_SDK_INSTALL_DIR/aarch64-zephyr-elf/bin/aarch64-zephyr-elf-gcc" ]] || missing+=("aarch64-zephyr-elf")
[[ -x "$ZEPHYR_SDK_INSTALL_DIR/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"       ]] || missing+=("arm-zephyr-eabi")
if [[ ${#missing[@]} -gt 0 ]]; then
  west sdk install $(printf -- " -t %s" "${missing[@]}") || {
    warn "[!] west sdk install 失败；若你已手动下载安装器到 $ZEPHYR_SDK_INSTALL_DIR："
    echo "    \"$ZEPHYR_SDK_INSTALL_DIR/setup.sh\" $(printf -- " -t %s" "${missing[@]}")"
    exit 4
  }
else
  ok "   -> 工具链已就绪，跳过安装"
fi
# 如需强制使用仓库内 SDK，可先 mv /root/zephyr-sdk-*/ 到备份名，并清 ~/.cmake/packages/Zephyr-sdk 再安装。

# ---- [6/8] 安装 mcumgr 到 $GOBIN ----
log "[6/8] 安装 mcumgr 到 $GOBIN"
if ! command -v mcumgr >/dev/null 2>&1; then
  [[ -x "$GOBIN/mcumgr" ]] || go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
  export PATH="$GOBIN:$PATH"
fi

# ---- [7/8] 构建演示：qemu_cortex_a53 + MCUboot + smp_svr（串口） ----
log "[7/8] 构建演示（qemu_cortex_a53 + MCUboot + smp_svr, serial）"
if [[ -x ./scripts/build.sh ]]; then
  ./scripts/build.sh -b qemu_cortex_a53 -t serial
else
  APP="$ROOT/zephyr/samples/subsys/mgmt/mcumgr/smp_svr"
  [[ -d "$APP" ]] || { err "[X] 不存在：$APP"; exit 6; }
  west build -b qemu_cortex_a53 --sysbuild "$APP" -d build \
    -- -DCONFIG_BOOTLOADER_MCUBOOT=y \
       -DEXTRA_CONF_FILE="$APP/overlay-serial.conf"
fi

# ---- [8/8] 运行（QEMU 串口） ----
log "[8/8] 运行（QEMU 串口）"
if [[ -x ./scripts/run.sh ]]; then
  ./scripts/run.sh || true
else
  west build -d build -t run || true
fi

cat <<'MSG'

============================================================
下一步（串口模式）：
1) 在 QEMU 输出中找到 /dev/pts/<N>
2) 新终端：
   source .venv/bin/activate
   export PATH="$(pwd)/tools/bin:$PATH"
   export SERIAL_DEV=/dev/pts/<N>
   ./scripts/mcumgr.sh serial-list
============================================================
MSG

ok "全部完成 ✅"
