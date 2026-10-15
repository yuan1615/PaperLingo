#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/.runtime"
mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/downloads" "$RUNTIME_DIR/logs"
export UV_CACHE_DIR="$RUNTIME_DIR/uv-cache"
export UV_PYTHON_INSTALL_DIR="$RUNTIME_DIR/python"
export HF_HOME="$RUNTIME_DIR/huggingface"
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_TIMEOUT=60
export OLLAMA_MODELS="$RUNTIME_DIR/ollama-models"
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_NO_CLOUD=1
export OLLAMA_CONTEXT_LENGTH=4096
export NO_PROXY="127.0.0.1,localhost"
cd "$PROJECT_ROOT"

if [ ! -x "$RUNTIME_DIR/bin/uv" ]; then
  echo '1/5 下载项目内 Python 安装工具 uv'
  curl -L --fail --retry 3 https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz -o "$RUNTIME_DIR/downloads/uv.tar.gz"
  tar -xzf "$RUNTIME_DIR/downloads/uv.tar.gz" -C "$RUNTIME_DIR/downloads"
  cp "$RUNTIME_DIR/downloads/uv-aarch64-apple-darwin/uv" "$RUNTIME_DIR/bin/uv"
fi
UV_BIN="$RUNTIME_DIR/bin/uv"
echo '2/5 安装隔离 Python 3.11 与 OmniVoice（首次需要数 GB 下载）'
if [ ! -x "$RUNTIME_DIR/venv/bin/python" ]; then
  "$UV_BIN" venv --python 3.11.17 "$RUNTIME_DIR/venv"
fi
"$UV_BIN" pip install --python "$RUNTIME_DIR/venv/bin/python" -r "$PROJECT_ROOT/engine/requirements.txt"
echo '3/5 下载 OmniVoice 模型及其音频 tokenizer'
"$RUNTIME_DIR/venv/bin/python" "$PROJECT_ROOT/engine/download_models.py"
if [ ! -x "$RUNTIME_DIR/bin/ollama" ]; then
  echo '4/5 下载 Ollama macOS 本地运行时'
  "$RUNTIME_DIR/venv/bin/python" "$PROJECT_ROOT/engine/download_file.py" https://github.com/ollama/ollama/releases/download/v0.40.4/ollama-darwin.tgz "$RUNTIME_DIR/downloads/ollama-complete.tgz" 167884528 --seed "$RUNTIME_DIR/downloads/ollama.tgz"
  mkdir -p "$RUNTIME_DIR/ollama"
  tar -xzf "$RUNTIME_DIR/downloads/ollama-complete.tgz" -C "$RUNTIME_DIR/ollama"
  OLLAMA_FOUND="$(find "$RUNTIME_DIR/ollama" -type f -name ollama -perm +111 | head -1)"
  if [ -z "$OLLAMA_FOUND" ]; then echo 'Ollama archive does not contain a CLI executable'; exit 1; fi
  ln -sf "$OLLAMA_FOUND" "$RUNTIME_DIR/bin/ollama"
fi
echo '5/5 下载 TranslateGemma 4B（约 3.3 GB）'
OWNED_OLLAMA_PID=''
cleanup() { if [ -n "$OWNED_OLLAMA_PID" ]; then kill "$OWNED_OLLAMA_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
if ! curl --noproxy '*' -fsS http://127.0.0.1:11434/api/version >/dev/null; then
  "$RUNTIME_DIR/bin/ollama" serve >"$RUNTIME_DIR/logs/setup-ollama.log" 2>&1 &
  OWNED_OLLAMA_PID=$!
  for attempt in {1..30}; do
    if curl --noproxy '*' -fsS http://127.0.0.1:11434/api/version >/dev/null; then break; fi
    sleep 1
  done
fi
"$RUNTIME_DIR/bin/ollama" pull translategemma:4b
echo '本地模型安装完成。打开 PaperLingo，在设置中启动引擎。'
