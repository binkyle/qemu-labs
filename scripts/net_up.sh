
#!/usr/bin/env bash
set -euo pipefail
TOP="$(git rev-parse --show-toplevel)"
cd "$TOP/zephyr/tools"
if [ ! -d net-tools ]; then
  git clone https://github.com/zephyrproject-rtos/net-tools
fi
cd net-tools
# 启动 host <-> QEMU 的 TAP/bridge（默认接口 zeth，默认配置 zeth.conf）
# 运行期间请保持此脚本终端开启；Ctrl-C 停止并清理
sudo ./net-setup.sh
