
#!/usr/bin/env bash
set -euo pipefail
sudo apt update
sudo apt install -y git cmake ninja-build python3-pip python3-venv                         device-tree-compiler dfu-util g++ make golang
pip3 install --user -U west
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo "[+] Next steps:"
echo "    west init -l . && west update && west zephyr-export"
echo "    west sdk install    # optional but recommended"
echo "    ./scripts/net_up.sh # for UDP transport"
