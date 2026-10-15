#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$PROJECT_ROOT/dist/PaperLingo-0.1.0-Offline"
APP_DIR="$STAGE/PaperLingo.app"
DMG="$PROJECT_ROOT/dist/PaperLingo-0.1.0-macOS-arm64-offline.dmg"
cd "$PROJECT_ROOT"
if [ "$(uname -m)" != arm64 ]; then echo 'Build this offline distribution on Apple Silicon.'; exit 1; fi
if [ "${PAPERLINGO_IMAGE_ONLY:-0}" != 1 ]; then
if [ -d "$APP_DIR/Contents/Resources/Runtime" ]; then echo 'Offline runtime already staged. Move the previous stage aside before rebuilding.'; exit 1; fi
mkdir -p "$STAGE"
PAPERLINGO_APP_DIR="$APP_DIR" bash scripts/build-app.sh
PYTHONDONTWRITEBYTECODE=1 "$PROJECT_ROOT/.runtime/venv/bin/python" scripts/prepare-offline.py "$PROJECT_ROOT" "$APP_DIR"
# Sign the final resource tree after all paths, models and notices are in place.
codesign --force --deep --sign "${PAPERLINGO_SIGN_IDENTITY:--}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
cp packaging/INSTALL-zh.txt "$STAGE/安装说明.txt"
ln -s /Applications "$STAGE/Applications"
cp packaging/third-party/Notice "$STAGE/Notice"
fi
# Stage only lets QA copy/relocate the exact signed bundle before building the DMG.
if [ "${PAPERLINGO_STAGE_ONLY:-0}" = 1 ]; then echo "Staged: $APP_DIR"; exit 0; fi
test -f "$APP_DIR/Contents/Resources/distribution.json"
codesign --verify --deep --strict "$APP_DIR"
hdiutil create -volname 'PaperLingo 0.1.0 Offline' -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=1 "$DMG"
(cd "$PROJECT_ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built offline image: $DMG"
