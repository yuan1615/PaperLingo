#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$PROJECT_ROOT/.runtime/logs"
echo '即将在项目 .runtime 目录安装 Python、OmniVoice 和 TranslateGemma。首次需联网，预计占用约 10–15 GB。'
bash "$PROJECT_ROOT/scripts/setup-local.sh" 2>&1 | tee "$PROJECT_ROOT/.runtime/logs/install.log"
echo '完成。按回车关闭。'
read -r
