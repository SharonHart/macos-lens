#!/bin/bash
# Builds a universal (Apple silicon + Intel) release of macOS Lens and packages it:
#   dist/macOS-Lens-<version>.zip   app archive used by install.sh and the Homebrew cask
#   dist/macOS-Lens-<version>.dmg   drag-to-Applications disk image
#   dist/SHA256SUMS                 checksums for both
# The version comes from Resources/Info.plist. The app is ad-hoc signed, and packaging never changes
# Screen Recording permissions. Casks/macos-lens.rb is updated to match the new zip.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ -n "$VERSION" ]] || die "CFBundleShortVersionString is missing from Resources/Info.plist."
NAME="macOS-Lens-$VERSION"
DIST="$ROOT/dist"
STAGE="$ROOT/.build/package"
APP="$STAGE/macOS Lens.app"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"
CASK="$ROOT/Casks/macos-lens.rb"

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"

build() { # <arch>: builds the release executable and prints its path
    local triple="$1-apple-macosx14.0" dir
    swift build -c release --triple "$triple" >&2 || return 1
    dir="$(swift build -c release --triple "$triple" --show-bin-path)" || return 1
    [[ -x "$dir/MacOSLens" ]] || return 1
    printf '%s/MacOSLens\n' "$dir"
}

step "Building macOS Lens $VERSION for arm64"
ARM64_BIN="$(build arm64)" || die "The arm64 release build failed."

step "Building macOS Lens $VERSION for x86_64"
X86_LOG="$STAGE/x86_64-build.log"
if X86_BIN="$(build x86_64 2>"$X86_LOG")"; then
    lipo -create -output "$STAGE/MacOSLens" "$ARM64_BIN" "$X86_BIN"
else
    tail -n 20 "$X86_LOG" >&2 || true
    warn "The x86_64 build failed (full log: $X86_LOG)."
    warn "Packaging an arm64-only app: it runs on Apple silicon Macs but NOT on Intel Macs."
    cp "$ARM64_BIN" "$STAGE/MacOSLens"
fi
ARCHS="$(lipo -archs "$STAGE/MacOSLens")"

step "Assembling and ad-hoc signing the app ($ARCHS)"
MACOS_LENS_BINARY="$STAGE/MacOSLens" MACOS_LENS_APP="$APP" MACOS_LENS_SKIP_TCC_RESET=1 bash scripts/build-app.sh
codesign --verify --deep --strict "$APP"

step "Creating $NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Creating $NAME.dmg"
DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/macOS Lens.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "macOS Lens" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

step "Writing SHA256SUMS"
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" >SHA256SUMS)
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Zips aren't byte-for-byte reproducible, so the cask must follow every package run.
if [[ -f "$CASK" ]]; then
    sed -i '' -E -e "s/^(  version )\"[^\"]*\"/\\1\"$VERSION\"/" -e "s/^(  sha256 )\"[^\"]*\"/\\1\"$ZIP_SHA\"/" "$CASK"
    grep -q "^  version \"$VERSION\"$" "$CASK" && grep -q "^  sha256 \"$ZIP_SHA\"$" "$CASK" ||
        die "Could not update version/sha256 in $CASK."
    step "Updated Casks/macos-lens.rb to $VERSION ($ZIP_SHA)"
else
    warn "Casks/macos-lens.rb not found; skipped the cask update."
fi

step "Done"
printf 'Architectures: %s\n' "$ARCHS"
[[ "$ARCHS" == *x86_64* ]] || printf 'NOTE: arm64 only, Intel Macs are not supported by this build.\n'
(cd "$DIST" && cat SHA256SUMS)
printf '%s\n' "$ZIP" "$DMG" "$DIST/SHA256SUMS"
