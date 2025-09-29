
#!/usr/bin/env bash
set -euo pipefail
BUILD_DIR="${1:-build}"
west build -d "${BUILD_DIR}" -t run
