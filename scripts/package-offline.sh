#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/packaging/Info.plist")
STAGE="$PROJECT_ROOT/dist/PaperLingo-$VERSION-Offline"
APP_DIR="$STAGE/PaperLingo.app"
DMG="$PROJECT_ROOT/dist/PaperLingo-$VERSION-macOS-arm64-offline.dmg"
cd "$PROJECT_ROOT"
if [ "$(uname -m)" != arm64 ]; then echo 'Build this offline distribution on Apple Silicon.'; exit 1; fi
if [ "${PAPERLINGO_IMAGE_ONLY:-0}" != 1 ]; then
if [ -d "$APP_DIR/Contents/Resources/Runtime" ]; then echo 'Offline runtime already staged. Move the previous stage aside before rebuilding.'; exit 1; fi
mkdir -p "$STAGE"
PAPERLINGO_APP_DIR="$APP_DIR" bash scripts/build-app.sh
PYTHONDONTWRITEBYTECODE=1 "$PROJECT_ROOT/.runtime/venv/bin/python" scripts/prepare-offline.py "$PROJECT_ROOT" "$APP_DIR"
# Sign the final resource tree after all paths, models and notices are in place.
codesign --force --deep --sign "${PAPERLINGO_SIGN_IDENTITY:--}" "$APP_DIR"
python3 "$PROJECT_ROOT/scripts/replace-executable.py" "$APP_DIR/Contents/MacOS/PaperLingo" "$APP_DIR/Contents/MacOS/PaperLingo"
codesign --verify --deep --strict "$APP_DIR"
cp packaging/INSTALL-zh.txt "$STAGE/安装说明.txt"
ln -s /Applications "$STAGE/Applications"
cp packaging/third-party/Notice "$STAGE/Notice"
fi
# Stage only lets QA copy/relocate the exact signed bundle before building the DMG.
if [ "${PAPERLINGO_STAGE_ONLY:-0}" = 1 ]; then echo "Staged: $APP_DIR"; exit 0; fi
test -f "$APP_DIR/Contents/Resources/distribution.json"
codesign --verify --deep --strict "$APP_DIR"
# Leave room for the image and hdiutil's temporary work before compressing.
python3 - "$STAGE" <<'PY'
from pathlib import Path
import shutil,sys
stage=Path(sys.argv[1])
size=sum(p.stat().st_size for p in stage.rglob('*') if p.is_file())
needed=2*size+2*1024**3
if shutil.disk_usage(stage).free<needed:
    raise SystemExit(f'DMG creation needs at least {needed/1024**3:.1f} GiB free; staged app preserved.')
PY
# LZFSE is supported by the app's macOS 14+ target and avoids slow zlib
# compression when the distribution contains tens of gigabytes of weights.
hdiutil create -volname "PaperLingo $VERSION Offline" -srcfolder "$STAGE" -ov -format ULFO -puppetstrings "$DMG"
(cd "$PROJECT_ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built offline image: $DMG"
