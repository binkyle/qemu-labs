#!/usr/bin/env bash
# QEMU-Labs 一键环境搭建（幂等，全部安装在仓库内；WSL2 友好，串口模式）
set -Eeuo pipefail

# ------- 颜色 -------
RESET='\033[0m'; CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
log() { printf "${CYAN}%s${RESET}\n" "$*"; }
ok()  { printf "${GREEN}%s${RESET}\n" "$*"; }
warn(){ printf "${YELLOW}%s${RESET}\n" "$*"; }
err() { printf "${RED}%s${RESET}\n" "$*"; }

# ------- 参数 -------
REINIT=0; REBUILD=0; NOBUILD=0; NORUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinit)  REINIT=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --no-build) NOBUILD=1; shift ;;
    --no-run)   NORUN=1; shift ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

# ------- 路径 -------
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPO="$(basename "$ROOT")"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$ROOT/.zephyr-sdk}"
export GOBIN="$ROOT/tools/bin"
mkdir -p "$GOBIN"

test -f west.yml || { err "[X] 未找到 west.yml；请在仓库根运行。当前: $ROOT"; exit 2; }

# ------- 1) 系统依赖（幂等） -------
log "[1/9] 检查/安装系统依赖"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  xz-utils p7zip-full unzip tar curl wget file make gcc g++ \
  golang build-essential

git config --global core.autocrlf input || true
git config --global fetch.prune true || true

# ------- 2) venv + west 依赖 -------
log "[2/9] Python venv 与 west 依赖"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
# shellcheck disable=SC1091
source .venv/bin/activate
python - <<'PY' || {
  python -m pip install -U pip setuptools wheel
  python -m pip install -U west semver patool requests tqdm pyyaml colorama psutil
}
import importlib,sys
for m in ("west","semver","patoolib"):
    assert importlib.util.find_spec(m), f"missing {m}"
print("west deps OK @", sys.executable)
PY
hash -r 2>/dev/null || true

# ------- 3) west 工作区（topdir=仓库根） -------
log "[3/9] 初始化/检查 west 工作区（topdir=仓库根）"
need_init=$REINIT
if [ $need_init -eq 0 ]; then
  [ -d .west ] || need_init=1
fi
if [ $need_init -eq 0 ]; then
  TD="$(west topdir 2>/dev/null || true)"
  [[ "$TD" == "$ROOT" ]] || need_init=1
fi

if [ $need_init -eq 1 ]; then
  # 清理可能干扰的父目录 .west
  [ -d ../.west ] && mv ../.west "../.west.bak.$(date +%s)" || true
  rm -rf .west

  # 写一个最小且“路径固定”的 manifest（self.path: .；zephyr.path: zephyr）
  cp -a west.yml "west.yml.bak.$(date +%s)" || true
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
  west init -l .
  log "   -> west update（首次较久）"
  west update
else
  ok "   -> 已初始化，跳过 west init"
  if [ ! -d "$ROOT/zephyr" ]; then
    warn "   -> 未看到 $ROOT/zephyr，进行一次 west update"
    west update
  else
    ok "   -> 已存在 $ROOT/zephyr，跳过 west update"
  fi
fi

TD="$(west topdir)"
if [ "$TD" != "$ROOT" ]; then
  err "[X] west topdir=$TD 不是仓库根=$ROOT；请删除父目录 .west 后重试。"
  exit 3
fi
test -d "$ROOT/zephyr" || { err "[X] 未找到 $ROOT/zephyr；west update 失败？"; exit 3; }
log "   workspace topdir: $TD"
log "   zephyr base     : $ROOT/zephyr"

# ------- 4) hal_nxp 兜底（缺失才处理） -------
log "[4/9] 校验 hal_nxp 模块"
HAL_DIR="$ROOT/modules/hal/nxp"
if [ ! -d "$HAL_DIR" ]; then
  warn "   -> 缺少 hal_nxp，尝试定向 update"
  if ! west update -v hal_nxp; then
    warn "   -> 定向失败，清理后全量重试"
    rm -rf "$ROOT/modules/hal" 2>/dev/null || true
    west update
  fi
fi
if [ ! -d "$HAL_DIR" ]; then
  err "[X] 仍未获取 hal_nxp：$HAL_DIR"
  echo "    建议把仓库放到 WSL 的 Linux 目录（~/qemu-labs）后重试，或配置代理再 west update。"
  exit 4
else
  ok "   -> hal_nxp OK"
fi

# ------- 5) SDK（只装缺的工具链） -------
log "[5/9] Zephyr SDK 检查/安装（仅 ARM / AArch64）"
missing=()
[ -x "$ZEPHYR_SDK_INSTALL_DIR/aarch64-zephyr-elf/bin/aarch64-zephyr-elf-gcc" ] || missing+=("aarch64-zephyr-elf")
[ -x "$ZEPHYR_SDK_INSTALL_DIR/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc" ]       || missing+=("arm-zephyr-eabi")
if [ ${#missing[@]} -eq 0 ]; then
  ok "   -> 工具链已就绪，跳过 SDK 安装"
else
  log "   -> 缺少: ${missing[*]}，开始按需安装到 $ZEPHYR_SDK_INSTALL_DIR"
  west sdk install $(printf -- " -t %s" "${missing[@]}") || {
    err "[X] west sdk install 失败。若你已手动下载安装器到 $ZEPHYR_SDK_INSTALL_DIR："
    echo "    \"$ZEPHYR_SDK_INSTALL_DIR/setup.sh\" $(printf -- " -t %s" "${missing[@]}")"
    exit 5
  }
fi

# ------- 6) mcumgr（缺则安装到仓库内） -------
log "[6/9] mcumgr 检查/安装"
if command -v mcumgr >/dev/null 2>&1; then
  ok "   -> 检测到系统已有 mcumgr（继续使用系统的）"
else
  if [ ! -x "$GOBIN/mcumgr" ]; then
    log "   -> 安装到 $GOBIN"
    go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest || true
  fi
  export PATH="$GOBIN:$PATH"
  command -v mcumgr >/dev/null 2>&1 || warn "   -> mcumgr 不在 PATH（可手动 export PATH=\"$GOBIN:\$PATH\"）"
fi

# ------- 7) 构建（已产物且非 --rebuild 则跳过） -------
APP_ABS="$ROOT/zephyr/samples/subsys/mgmt/mcumgr/smp_svr"
OUT_DIR="build"
SIGNED="$OUT_DIR/zephyr/zephyr.signed.bin"

log "[7/9] 构建示例（qemu_cortex_a53 + MCUboot + smp_svr, serial 模式）"
if [ $NOBUILD -eq 1 ]; then
  warn "   -> 按参数 --no-build 跳过构建"
else
  if [ -f "$SIGNED" ] && [ $REBUILD -eq 0 ]; then
    ok "   -> 产物已存在：$SIGNED，跳过构建（--rebuild 可强制重建）"
  else
    if [ -x ./scripts/build.sh ]; then
      ./scripts/build.sh -b qemu_cortex_a53 -t serial
    else
      OVERLAY_SERIAL="$APP_ABS/overlay-serial.conf"
      test -d "$APP_ABS" || { err "[X] 不存在：$APP_ABS"; exit 6; }
      west build -b qemu_cortex_a53 --sysbuild "$APP_ABS" -d "$OUT_DIR" \
        -- -DCONFIG_BOOTLOADER_MCUBOOT=y -DCONFIG_MCUBOOT_LOG_LEVEL_INF=y \
           -DEXTRA_CONF_FILE="$OVERLAY_SERIAL"
    fi
  fi
fi

# ------- 8) 运行（可跳过） -------
log "[8/9] 运行示例（QEMU 串口）"
if [ $NORUN -eq 1 ] || [ $NOBUILD -eq 1 ]; then
  warn "   -> 按参数跳过运行"
else
  if [ -x ./scripts/run.sh ]; then
    ./scripts/run.sh || true
  else
    west build -d "$OUT_DIR" -t run || true
  fi
fi

# ------- 9) 提示 -------
log "[9/9] 完成。下一步（串口模式）："
cat <<'MSG'
  1) 在 QEMU 输出中找到 /dev/pts/<N>
  2) 新终端：
       source .venv/bin/activate
       export PATH="$(pwd)/tools/bin:$PATH"
       export SERIAL_DEV=/dev/pts/<N>
       ./scripts/mcumgr.sh serial-list
  升级流程（示例）：
       ./scripts/mcumgr.sh serial-upload
       ./scripts/mcumgr.sh serial-test <hash>
       ./scripts/mcumgr.sh serial-reset
       ./scripts/mcumgr.sh serial-confirm
MSG

ok "== 环境就绪 ✅  west topdir => $(west topdir)"
printf "ZEPHYR_SDK_INSTALL_DIR => %s\n" "$ZEPHYR_SDK_INSTALL_DIR"
