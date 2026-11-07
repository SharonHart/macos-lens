#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/macOS Lens.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacOSLens "$APP/Contents/MacOS/MacOSLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.macos-lens.client "$APP"
printf 'Built %s\n' "$APP"
