#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional overrides (used by package.sh and install.sh; defaults keep the plain developer build):
#   MACOS_LENS_BINARY=<path>       bundle an already-built executable instead of running swift build
#   MACOS_LENS_APP=<path>          where to assemble the app (default: dist/macOS Lens.app)
#   MACOS_LENS_SIGN_IDENTITY=<id>  sign with this Developer ID Application identity, with the Hardened Runtime and a
#                                  secure timestamp, instead of ad-hoc (default: -, ad-hoc)
BINARY="${MACOS_LENS_BINARY:-}"
if [[ -z "$BINARY" ]]; then
    swift build -c release
    BINARY=.build/release/MacOSLens
fi
APP="${MACOS_LENS_APP:-dist/macOS Lens.app}"
# The icon is drawn from the brand mark by scripts/dmg/DMGArt.swift with the app's LensMark.swift, the same code as the
# disk image art, and cached by the hash of both sources.
ART_SOURCES=(Sources/MacOSLens/LensMark.swift scripts/dmg/DMGArt.swift)
ICON_DIR=".build/app-icon/$(cat "${ART_SOURCES[@]}" | shasum -a 256 | cut -c1-16)"
if [[ ! -f "$ICON_DIR/AppIcon.icns" ]]; then
    rm -rf "$ICON_DIR"
    mkdir -p "$ICON_DIR"
    swiftc -O -parse-as-library -module-name DMGArt "${ART_SOURCES[@]}" -o "$ICON_DIR/dmg-art"
    "$ICON_DIR/dmg-art" icon "$ICON_DIR/AppIcon.iconset"
    iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.tmp.icns"
    mv "$ICON_DIR/AppIcon.tmp.icns" "$ICON_DIR/AppIcon.icns"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/MacOSLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${MACOS_LENS_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == - ]]; then
    codesign --force --sign - --identifier dev.macos-lens.client "$APP"
else
    # Notarization needs the Hardened Runtime and a secure timestamp. The app needs no entitlements under it.
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier dev.macos-lens.client "$APP"
fi
printf 'Built %s\n' "$APP"
