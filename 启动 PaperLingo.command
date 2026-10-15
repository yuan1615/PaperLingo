#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_ROOT/dist/PaperLingo.app"
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/packaging/Info.plist")
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)
if [ ! -d "$APP_DIR" ] || [ "$APP_VERSION" != "$SOURCE_VERSION" ]; then bash "$PROJECT_ROOT/scripts/build-app.sh"; fi
open "$APP_DIR"
