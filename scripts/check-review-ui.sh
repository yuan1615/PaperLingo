#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# Fresh directory and bundle identifier isolate both records and preferences.
mkdir -p "$PROJECT_ROOT/.test-output"
QA_DIR="$(mktemp -d "$PROJECT_ROOT/.test-output/review-ui.XXXXXX")"
QA_APP="$QA_DIR/ReviewChecks.app"
mkdir -p "$QA_APP/Contents/MacOS" "$QA_APP/Contents/Resources/engine" "$QA_DIR/data"
cp engine/server.py engine/rerank.py "$QA_APP/Contents/Resources/engine/"
python3 - "$PROJECT_ROOT" "$QA_DIR" "$QA_APP" <<'PY'
import hashlib, io, json, os, plistlib, sys, uuid, wave
from pathlib import Path
root, work, app = map(Path, sys.argv[1:])
info = plistlib.loads((root/'packaging/Info.plist').read_bytes())
info.update(CFBundleExecutable='ReviewChecks', CFBundleName='PaperLingo Review Checks', CFBundleIdentifier='local.paperlingo.reviewqa.' + uuid.uuid4().hex)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(app/'Contents/Resources/runtime.json').write_text(json.dumps({'data':str(work/'data')}))
if os.environ.get('PAPERLINGO_REFERENCE_VOICE_FIXTURE')=='1':
    voices=app/'Contents/Resources/voice-prompts';voices.mkdir()
    entries=[]
    for identifier in ('001','002','003'):
        buffer=io.BytesIO()
        with wave.open(buffer,'wb') as clip:
            clip.setnchannels(1);clip.setsampwidth(2);clip.setframerate(24000);clip.writeframes(b'\x01\x00'*48000)
        audio=buffer.getvalue();(voices/(identifier+'.wav')).write_bytes(audio)
        entries.append({'id':identifier,'label':'声音 '+identifier,'file':identifier+'.wav','text':'Synthetic reference.','sha256':hashlib.sha256(audio).hexdigest()})
    (voices/'manifest.json').write_text(json.dumps({'version':1,'voices':entries}))
PY
swift build -c release --disable-sandbox --scratch-path "$PROJECT_ROOT/.build" -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache"
APP_SOURCES=()
for source in Sources/PaperLingo/*.swift; do
  if [[ "$source" != */PaperLingoApp.swift ]]; then APP_SOURCES+=("$source"); fi
done
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -module-cache-path .build/ModuleCache -I .build/release/Modules -I Sources/CSQLite \
  "${APP_SOURCES[@]}" "${PAPERLINGO_UI_CHECK_SOURCE:-Tests/PaperLingoUITests/ReviewLayoutChecks.swift}" \
  .build/release/PaperCore.build/*.o -lsqlite3 -o "$QA_APP/Contents/MacOS/ReviewChecks"
codesign --force --sign - "$QA_APP"
PAPERLINGO_DATA_DIR="$QA_DIR/data" PAPERLINGO_ENGINE_WORK_DIR="$QA_DIR/Engine" \
  "$QA_APP/Contents/MacOS/ReviewChecks" "$QA_DIR" 2>&1 | tee "$QA_DIR/checks.log"
echo "Review UI verification: $QA_DIR"
