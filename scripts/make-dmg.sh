#!/bin/bash
# Builds the drag-to-Applications disk images and SHA256SUMS from a packaged app:
#   dist/macOS-Lens-<version>.dmg   branded Finder window: background, icon positions and the volume icon
#   dist/macOS-Lens.dmg             a byte-identical copy without the version, for releases/latest/download links
#   dist/SHA256SUMS                 checksums for the zip and both disk images
#
# Usage: scripts/make-dmg.sh [path/to/macOS Lens.app]
# scripts/package.sh passes the app it just built. Without an argument the app comes from
# dist/macOS-Lens-<version>.zip, which is left untouched, so the disk images can be rebuilt without a new zip.
#
# Finder and AppleScript are never used, so it runs headless: the window layout is written straight into the image's
# .DS_Store by dmgbuild (through scripts/dmg/build.py, which keeps the writable image out of /Volumes), installed with
# pinned hashes into a venv under ~/Library/Caches/macos-lens (needs Python 3.9 or later, and the network the first
# time). The background is drawn by scripts/dmg/DMGArt.swift, compiled together with the app's LensMark.swift, and
# the volume icon is the app's own AppIcon.icns. Set MACOS_LENS_DMG_QA=<dir> to also write light and dark previews
# of the window there.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NAME="macOS-Lens-$VERSION"
VOLUME="macOS Lens"
DIST="$ROOT/dist"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"
LATEST_DMG="$DIST/macOS-Lens.dmg"
CACHE="$HOME/Library/Caches/macos-lens"
REQUIREMENTS="$ROOT/scripts/dmg/requirements.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-lens-dmg.XXXXXX")"
MOUNT=""
cleanup() {
    if [[ -n "$MOUNT" ]]; then hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" || true; fi
    # dmgbuild normally detaches its writable image itself; don't let rm walk into it if it failed half way.
    if [[ -d "$WORK/writable" && "$(stat -f %d "$WORK/writable")" != "$(stat -f %d "$WORK")" ]]; then
        hdiutil detach -quiet "$WORK/writable" 2>/dev/null || hdiutil detach -quiet -force "$WORK/writable" || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

[[ -f "$ZIP" ]] || die "$ZIP is missing; run scripts/package.sh first."
APP="${1:-}"
if [[ -z "$APP" ]]; then
    ditto -x -k "$ZIP" "$WORK/app"
    APP="$WORK/app/macOS Lens.app"
fi
APP="${APP%/}"
[[ -d "$APP" ]] || die "No app at $APP."
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || die "The app is version $APP_VERSION, but Resources/Info.plist says $VERSION."
APP_NAME="$(basename "$APP")"

step "Drawing the window background"
ART="$WORK/art"
swiftc -O -parse-as-library -module-name DMGArt Sources/MacOSLens/LensMark.swift scripts/dmg/DMGArt.swift -o "$WORK/dmg-art"
"$WORK/dmg-art" render "$ART" scripts/dmg/Urbanist-Variable.ttf
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null
# The volume shows the app's own icon, which scripts/build-app.sh draws from the same mark.
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$ICON_FILE" ]] || die "The app has no CFBundleIconFile."
VOLUME_ICON="$APP/Contents/Resources/${ICON_FILE%.icns}.icns"
[[ -f "$VOLUME_ICON" ]] || die "The app names the icon $ICON_FILE, but $VOLUME_ICON is missing."

step "Preparing dmgbuild"
PYTHON="${PYTHON:-python3}"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null ||
    die "dmgbuild needs Python 3.9 or later; set PYTHON to one."
PY_VERSION="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
VENV="$CACHE/dmgbuild-$(shasum -a 256 "$REQUIREMENTS" | cut -c1-12)-py$PY_VERSION"
if ! "$VENV/bin/python" -c 'import dmgbuild, ds_store, mac_alias' 2>/dev/null; then
    rm -rf "$VENV"
    mkdir -p "$CACHE"
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --no-deps --only-binary :all: \
        --require-hashes -r "$REQUIREMENTS"
fi

step "Building $NAME.dmg"
rm -f "$DMG"
"$VENV/bin/python" scripts/dmg/build.py --settings scripts/dmg/settings.py --mount-dir "$WORK/writable" \
    -D app="$APP" -D art="$ART" -D volume_icon="$VOLUME_ICON" "$VOLUME" "$DMG" >"$WORK/dmgbuild.log" 2>&1 ||
    { tail -n 30 "$WORK/dmgbuild.log" >&2; die "dmgbuild failed."; }
hdiutil verify -quiet "$DMG"

step "Checking the disk image"
# Mounted read-only where Finder would mount it, so the background alias is resolved exactly as on a user's Mac.
[[ ! -e "/Volumes/$VOLUME" ]] || die "Eject the \"$VOLUME\" volume that is already mounted, then run this again."
MOUNT="/Volumes/$VOLUME"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
diff -r "$APP" "$MOUNT/$APP_NAME" || die "The app in the disk image differs from $APP."
codesign --verify --deep --strict "$MOUNT/$APP_NAME" || die "The app in the disk image fails codesign --verify."
cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/ {print $2}'; }
[[ -n "$(cdhash "$APP")" && "$(cdhash "$APP")" == "$(cdhash "$MOUNT/$APP_NAME")" ]] || die "The app's cdhash changed."
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] || die "No Applications link."
cmp -s "$VOLUME_ICON" "$MOUNT/.VolumeIcon.icns" || die "The volume icon is missing."
# Finder shows .VolumeIcon.icns only when the volume root has kHasCustomIcon (0x0400) in its Finder info flags.
FLAGS="$(xattr -px com.apple.FinderInfo "$MOUNT" 2>/dev/null | tr -d ' \n' | cut -c17-18)"
[[ -n "$FLAGS" ]] && (( 0x$FLAGS & 0x04 )) || die "The volume's custom icon flag isn't set."
"$VENV/bin/python" scripts/dmg/check_dsstore.py "$MOUNT" "$ART/layout.json" "$APP_NAME" "$VOLUME" >"$WORK/dsstore.json"
EXPECTED="$MOUNT/.background.tiff"
read -r ALIAS_HEX BOOKMARK_HEX < <("$VENV/bin/python" -c \
    'import json, sys; d = json.load(open(sys.argv[1])); print(d["alias"]["hex"], d["bookmark_hex"])' "$WORK/dsstore.json")
RESOLVED="$("$WORK/dmg-art" resolve "$ALIAS_HEX" "$BOOKMARK_HEX")"
[[ "$RESOLVED" == "alias $EXPECTED"$'\n'"bookmark $EXPECTED" ]] ||
    die "The background doesn't resolve to $EXPECTED:"$'\n'"$RESOLVED"
printf 'Window %s, icons at %s, background alias and bookmark resolve on the volume, custom volume icon set.\n' \
    "$("$VENV/bin/python" -c 'import json, sys; w = json.load(open(sys.argv[1]))["window"]; print("%dx%d" % (w["width"], w["height"]))' "$WORK/dsstore.json")" \
    "$("$VENV/bin/python" -c 'import json, sys; print(json.load(open(sys.argv[1]))["icons"])' "$WORK/dsstore.json")"
if [[ -n "${MACOS_LENS_DMG_QA:-}" ]]; then
    mkdir -p "$MACOS_LENS_DMG_QA"
    cp "$WORK/dsstore.json" "$MACOS_LENS_DMG_QA/dmg.dsstore.json"
    "$WORK/dmg-art" preview "$WORK/dsstore.json" "$MOUNT" "$MACOS_LENS_DMG_QA"
fi
hdiutil detach -quiet "$MOUNT"
MOUNT=""

rm -f "$LATEST_DMG"
cp "$DMG" "$LATEST_DMG"
cmp -s "$DMG" "$LATEST_DMG" || die "$LATEST_DMG differs from $DMG."

step "Writing SHA256SUMS"
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" macOS-Lens.dmg >SHA256SUMS)
