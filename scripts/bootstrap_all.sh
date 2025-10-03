#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（幂等；强制 west topdir=仓库根；不会去父目录）
# version: 2025-10-02-fix-topdir-v3
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

# ---- 参数 ----
REBUILD=0; NOBUILD=0; NORUN=0; REINIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    --no-build) NOBUILD=1; shift ;;
    --no-run)   NORUN=1; shift ;;
    --reinit)   REINIT=1; shift ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

# ---- 路径 ----
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$ROOT/.zephyr-sdk}"
export GOBIN="$ROOT/tools/bin"; mkdir -p "$GOBIN"
HAL_DIR="$ROOT/modules/hal/nxp"
[[ -f west.yml ]] || { err "[X] 未找到 west.yml；请在仓库根运行。当前: $ROOT"; exit 2; }

# ---- 0) CRLF 提醒（可选） ----
if LC_ALL=C grep -q $'\r' "$0" 2>/dev/null; then
  warn "[!] 检测到 CRLF，建议先执行：sed -i 's/\\r$//' scripts/*.sh"
fi

# ---- 1) 系统依赖（幂等） ----
log "[1/9] 检查/安装系统依赖"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential
git config --global core.autocrlf input || true
git config --global fetch.prune true || true

# ---- 2) venv + west 依赖（强制 python3；缺才安装） ----
log "[2/9] Python venv 与 west 依赖"
[[ -d .venv ]] || python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 - <<'PY'
import sys
try:
  for m in ("west","semver","patoolib"): __import__(m)
  sys.exit(0)
except Exception:
  sys.exit(42)
PY
if [[ $? -eq 42 ]]; then
  python3 -m pip install -U pip setuptools wheel
  python3 -m pip install -U west semver patool requests tqdm pyyaml colorama psutil
fi
hash -r 2>/dev/null || true

# ---- 3) 锁定 workspace topdir=仓库根（预置 .west/config，免疫父目录吸走） ----
log "[3/9] 锁定 workspace 到仓库根（不会去父目录）"

# 3.0 处理父目录干扰；--reinit 时一并清理本地 .west
PARENT="${ROOT%/*}"
if [[ -d "$PARENT/.west" ]]; then
  warn "   -> 发现父目录 $PARENT/.west，已备份为 $PARENT/.west.bak.$(date +%s)"
  mv "$PARENT/.west" "$PARENT/.west.bak.$(date +%s)"
fi
[[ $REINIT -eq 1 && -d .west ]] && rm -rf .west

# 3.1 预置 .west/config（把 topdir 钉在当前仓库）
mkdir -p .west
cat > .west/config <<'CONF'
[manifest]
path = .
file = west.yml
CONF

# 3.2 写最小 manifest（保证 self.path = .；模块都在仓库内）
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

# 3.3 初始化到“当前目录”（即使失败也没关系；我们已预置好 .west/config）
west init -l . || true

# 3.3.1 若存在损坏的 hal_nxp 目录，先备份后让 west 重新克隆
backup_hal_nxp_dir() {
  local reason="$1"
  local ts target
  ts="$(date +%s)"
  target="${HAL_DIR}.bak.${ts}.${reason}.${RANDOM}"
  warn "   -> 检测到 hal_nxp 异常（${reason}），已备份至 ${target#$ROOT/}"
  mv "$HAL_DIR" "$target"
}

if [[ -e "$HAL_DIR" && ! -d "$HAL_DIR" ]]; then
  backup_hal_nxp_dir "not-a-directory"
elif [[ -d "$HAL_DIR" ]]; then
  if ! git -C "$HAL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    backup_hal_nxp_dir "no-git"
  else
    if ! git -C "$HAL_DIR" remote get-url upstream >/dev/null 2>&1; then
      backup_hal_nxp_dir "missing-upstream"
    elif [[ -n "$(git -C "$HAL_DIR" status --porcelain 2>/dev/null)" ]]; then
      backup_hal_nxp_dir "dirty"
    fi
  fi
fi

# 3.4 修正配置并拉取；校验 topdir 必须是仓库根
west config manifest.path .
west config manifest.file west.yml
if ! west update; then
  warn "   -> west update 首次执行失败，尝试清理后重试"
  if [[ -d "$HAL_DIR" ]]; then
    warn "   -> 重新命名 hal_nxp 目录后再拉取"
    backup_hal_nxp_dir "auto-retry"
  fi
  west update
fi

td="$(west topdir 2>/dev/null || true)"
if [[ "$td" != "$ROOT" ]]; then
  err "[X] west topdir=$td 仍不是仓库根=$ROOT"
  echo "    修正：rm -rf \"$PARENT/.west\"  .west  &&  bash scripts/bootstrap_all.sh --reinit"
  exit 3
fi
[[ -d "$ROOT/zephyr" ]] || { err "[X] 未找到 $ROOT/zephyr；west update 失败？"; exit 3; }
ok "   -> workspace OK：$td"

# ---- 4) hal_nxp 兜底（缺失才处理） ----
log "[4/9] 校验 hal_nxp 模块"
if [[ ! -d "$HAL_DIR" ]]; then
  warn "   -> 缺少 hal_nxp，定向 west update hal_nxp"
  if ! west update -v hal_nxp; then
    warn "   -> 定向失败，清理后全量重试"
    rm -rf "$ROOT/modules/hal" 2>/dev/null || true
    west update
  fi
fi
[[ -d "$HAL_DIR" ]] || { err "[X] 仍未获取 hal_nxp：$HAL_DIR"; exit 4; }
ok "   -> hal_nxp OK"

# ---- 5) SDK（只装缺的工具链到仓库内） ----
log "[5/9] Zephyr SDK 检查/安装（仅 ARM / AArch64）"
missing=()
[[ -x "$ZEPHYR_SDK_INSTALL_DIR/aarch64-zephyr-elf/bin/aarch64-zephyr-elf-gcc" ]] || missing+=("aarch64-zephyr-elf")
[[ -x "$ZEPHYR_SDK_INSTALL_DIR/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc" ]] || missing+=("arm-zephyr-eabi")
if [[ ${#missing[@]} -gt 0 ]]; then
  log "   -> 缺少: ${missing[*]}，开始按需安装到 $ZEPHYR_SDK_INSTALL_DIR"
  west sdk install $(printf -- " -t %s" "${missing[@]}") || {
    err "[X] west sdk install 失败（可手动执行 $ZEPHYR_SDK_INSTALL_DIR/setup.sh …）"; exit 5; }
else
  ok "   -> 工具链已就绪，跳过 SDK 安装"
fi

# ---- 6) mcumgr（缺则安装到仓库内） ----
log "[6/9] mcumgr 检查/安装"
if ! command -v mcumgr >/dev/null 2>&1; then
  [[ -x "$GOBIN/mcumgr" ]] || go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
  export PATH="$GOBIN:$PATH"
fi
command -v mcumgr >/dev/null 2>&1 || warn "   -> mcumgr 不在 PATH；手动 export PATH=\"$GOBIN:\$PATH\""

# ---- 7) 构建（产物已存在且未 --rebuild 则跳过） ----
APP_ABS="$ROOT/zephyr/samples/subsys/mgmt/mcumgr/smp_svr"
OUT_DIR="build"; SIGNED="$OUT_DIR/zephyr/zephyr.signed.bin"
log "[7/9] 构建示例（qemu_cortex_a53 + MCUboot + smp_svr, serial）"
if [[ $NOBUILD -eq 1 ]]; then
  warn "   -> 按参数 --no-build 跳过构建"
elif [[ -f "$SIGNED" && $REBUILD -eq 0 ]]; then
  ok "   -> 产物已存在：$SIGNED（--rebuild 可强制重建）"
else
  if [[ -x ./scripts/build.sh ]]; then
    ./scripts/build.sh -b qemu_cortex_a53 -t serial
  else
    OVERLAY_SERIAL="$APP_ABS/overlay-serial.conf"
    [[ -d "$APP_ABS" ]] || { err "[X] 不存在：$APP_ABS"; exit 6; }
    west build -b qemu_cortex_a53 --sysbuild "$APP_ABS" -d "$OUT_DIR" \
      -- -DCONFIG_BOOTLOADER_MCUBOOT=y -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
         -DEXTRA_CONF_FILE="$OVERLAY_SERIAL"
  fi
fi

# ---- 8) 运行（可跳过） ----
log "[8/9] 运行示例（QEMU 串口）"
if [[ $NORUN -eq 1 || $NOBUILD -eq 1 ]]; then
  warn "   -> 按参数跳过运行"
else
  [[ -x ./scripts/run.sh ]] && ./scripts/run.sh || west build -d "$OUT_DIR" -t run || true
fi

# ---- 9) 提示 ----
log "[9/9] 完成。下一步（串口模式）："
cat <<'MSG'
  1) 在 QEMU 输出中找到 /dev/pts/<N>
  2) 新终端：
       source .venv/bin/activate
       export PATH="$(pwd)/tools/bin:$PATH"
       export SERIAL_DEV=/dev/pts/<N>
       ./scripts/mcumgr.sh serial-list
MSG

ok "== 环境就绪 ✅  west topdir => $(west topdir)"
printf "ZEPHYR_SDK_INSTALL_DIR => %s\n" "$ZEPHYR_SDK_INSTALL_DIR"
