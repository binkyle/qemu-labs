
#!/usr/bin/env bash
set -euo pipefail
TOP="$(git rev-parse --show-toplevel)"
cd "$TOP/zephyr/tools/net-tools"
sudo ./net-setup.sh stop || true
