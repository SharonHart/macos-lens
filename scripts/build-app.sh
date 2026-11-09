#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional overrides (used by package.sh and install.sh; defaults keep the plain developer build):
#   MACOS_LENS_BINARY=<path>       bundle an already-built executable instead of running swift build
#   MACOS_LENS_APP=<path>          where to assemble the app (default: dist/macOS Lens.app)
BINARY="${MACOS_LENS_BINARY:-}"
if [[ -z "$BINARY" ]]; then
    swift build -c release
    BINARY=.build/release/MacOSLens
fi
APP="${MACOS_LENS_APP:-dist/macOS Lens.app}"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/MacOSLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.macos-lens.client "$APP"
printf 'Built %s\n' "$APP"
