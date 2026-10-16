#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release --disable-sandbox --scratch-path "$PROJECT_ROOT/.build" -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache"
APP_DIR="${PAPERLINGO_APP_DIR:-$PROJECT_ROOT/dist/PaperLingo.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/engine"
cp "$PROJECT_ROOT/.build/release/PaperLingo" "$APP_DIR/Contents/MacOS/PaperLingo"
python3 - "$PROJECT_ROOT" "$APP_DIR" <<'PY'
import json,sys
from pathlib import Path
(Path(sys.argv[2])/'Contents/Resources/runtime.json').write_text(json.dumps({'runtime':str(Path(sys.argv[1])/'.runtime')}))
PY
cp "$PROJECT_ROOT/engine/server.py" "$APP_DIR/Contents/Resources/engine/server.py"
cp "$PROJECT_ROOT/engine/rerank.py" "$APP_DIR/Contents/Resources/engine/rerank.py"
cp "$PROJECT_ROOT/packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
if [ -f "$PROJECT_ROOT/packaging/AppIcon.icns" ]; then cp "$PROJECT_ROOT/packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/"; fi
codesign --force --deep --sign "${PAPERLINGO_SIGN_IDENTITY:--}" "$APP_DIR"
echo "Built: $APP_DIR"
