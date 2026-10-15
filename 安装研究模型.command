#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$PROJECT_ROOT/.runtime/logs"
python3 "$PROJECT_ROOT/engine/install_research.py" 2>&1 | tee "$PROJECT_ROOT/.runtime/logs/research-install.log"
echo '完成。按回车关闭。'
read -r
