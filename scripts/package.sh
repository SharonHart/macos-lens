#!/bin/bash
# Builds a universal (Apple silicon + Intel) release of macOS Lens and packages it:
#   dist/macOS-Lens-<version>.zip   app archive used by install.sh and the Homebrew cask
#   dist/macOS-Lens-<version>.dmg   branded drag-to-Applications disk image (scripts/make-dmg.sh)
#   dist/macOS-Lens.dmg             the same disk image without the version, for releases/latest/download links
#   dist/SHA256SUMS                 checksums for all three
# The version comes from Resources/Info.plist. The app is ad-hoc signed unless MACOS_LENS_SIGN_IDENTITY names a
# Developer ID Application identity; with notarization credentials too (see scripts/notarize.sh), the app and the disk
# image are notarized and stapled. Set MACOS_LENS_REQUIRE_UNIVERSAL=1 to stop instead of packaging an arm64-only app.
# Packaging never changes Screen Recording permissions. Casks/macos-lens.rb is updated to match the new zip.
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
LATEST_DMG="$DIST/macOS-Lens.dmg"
CASK="$ROOT/Casks/macos-lens.rb"

IDENTITY="${MACOS_LENS_SIGN_IDENTITY:--}"
NOTARIZE=0
[[ -n "${MACOS_LENS_NOTARY_PROFILE:-}${MACOS_LENS_NOTARY_KEY:-}" ]] && NOTARIZE=1
((!NOTARIZE)) || [[ "$IDENTITY" != - ]] || die "Notarization needs MACOS_LENS_SIGN_IDENTITY set to a Developer ID identity."

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"

build() { # <arch>: builds the release executable and copies it to $STAGE/MacOSLens-<arch>
    local triple="$1-apple-macosx14.0" dir
    swift build -c release --triple "$triple" >&2 || return 1
    dir="$(swift build -c release --triple "$triple" --show-bin-path)" || return 1
    [[ -x "$dir/MacOSLens" ]] || return 1
    # Newer SwiftPM build systems use one bin folder for every triple, so the next build would overwrite this one.
    cp "$dir/MacOSLens" "$STAGE/MacOSLens-$1"
    [[ "$(lipo -archs "$STAGE/MacOSLens-$1")" == "$1" ]]
}

step "Building macOS Lens $VERSION for arm64"
build arm64 || die "The arm64 release build failed."

step "Building macOS Lens $VERSION for x86_64"
X86_LOG="$STAGE/x86_64-build.log"
if build x86_64 2>"$X86_LOG"; then
    lipo -create -output "$STAGE/MacOSLens" "$STAGE/MacOSLens-arm64" "$STAGE/MacOSLens-x86_64"
else
    tail -n 20 "$X86_LOG" >&2 || true
    [[ "${MACOS_LENS_REQUIRE_UNIVERSAL:-0}" != 1 ]] || die "The x86_64 build failed (full log: $X86_LOG)."
    warn "The x86_64 build failed (full log: $X86_LOG)."
    warn "Packaging an arm64-only app: it runs on Apple silicon Macs but NOT on Intel Macs."
    cp "$STAGE/MacOSLens-arm64" "$STAGE/MacOSLens"
fi
ARCHS="$(lipo -archs "$STAGE/MacOSLens")"

if [[ "$IDENTITY" == - ]]; then
    step "Assembling and ad-hoc signing the app ($ARCHS)"
else
    step "Assembling the app ($ARCHS) and signing it as $IDENTITY"
fi
MACOS_LENS_BINARY="$STAGE/MacOSLens" MACOS_LENS_APP="$APP" bash scripts/build-app.sh
codesign --verify --deep --strict "$APP"

# The zip and the disk image both carry the stapled app, so it opens offline without a Gatekeeper warning.
if ((NOTARIZE)); then
    bash scripts/notarize.sh "$APP"
fi

step "Creating $NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

bash scripts/make-dmg.sh "$APP"
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
printf '%s\n' "$ZIP" "$DMG" "$LATEST_DMG" "$DIST/SHA256SUMS"
