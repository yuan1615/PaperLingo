#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# Fresh directory and bundle identifier isolate both records and preferences.
mkdir -p "$PROJECT_ROOT/.test-output"
QA_DIR="$(mktemp -d "$PROJECT_ROOT/.test-output/review-ui.XXXXXX")"
QA_APP="$QA_DIR/ReviewChecks.app"
mkdir -p "$QA_APP/Contents/MacOS" "$QA_APP/Contents/Resources" "$QA_DIR/data"
python3 - "$PROJECT_ROOT" "$QA_DIR" "$QA_APP" <<'PY'
import json, plistlib, sys, uuid
from pathlib import Path
root, work, app = map(Path, sys.argv[1:])
info = plistlib.loads((root/'packaging/Info.plist').read_bytes())
info.update(CFBundleExecutable='ReviewChecks', CFBundleName='PaperLingo Review Checks', CFBundleIdentifier='local.paperlingo.reviewqa.' + uuid.uuid4().hex)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(app/'Contents/Resources/runtime.json').write_text(json.dumps({'data':str(work/'data')}))
PY
swift build -c release --disable-sandbox --scratch-path "$PROJECT_ROOT/.build" -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache"
APP_SOURCES=()
for source in Sources/PaperLingo/*.swift; do
  if [[ "$source" != */PaperLingoApp.swift ]]; then APP_SOURCES+=("$source"); fi
done
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -module-cache-path .build/ModuleCache -I .build/release/Modules -I Sources/CSQLite \
  "${APP_SOURCES[@]}" Tests/PaperLingoUITests/ReviewLayoutChecks.swift \
  .build/release/PaperCore.build/*.o -lsqlite3 -o "$QA_APP/Contents/MacOS/ReviewChecks"
codesign --force --sign - "$QA_APP"
PAPERLINGO_DATA_DIR="$QA_DIR/data" PAPERLINGO_ENGINE_WORK_DIR="$QA_DIR/Engine" \
  "$QA_APP/Contents/MacOS/ReviewChecks" "$QA_DIR" 2>&1 | tee "$QA_DIR/checks.log"
echo "Review UI verification: $QA_DIR"
