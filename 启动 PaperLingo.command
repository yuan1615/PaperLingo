#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$PROJECT_ROOT/dist/PaperLingo.app" ]; then bash "$PROJECT_ROOT/scripts/build-app.sh"; fi
open "$PROJECT_ROOT/dist/PaperLingo.app"
