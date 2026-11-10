#!/bin/bash
# Prepares a macOS Lens release: checks the version, runs the tests, packages the app, and prints (but doesn't
# run) the gh command that publishes it.
#
#   ./scripts/release.sh <version> [--skip-native-checks]
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="SharonHart/macos-lens"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION=""
NATIVE_CHECKS=1
[[ "${MACOS_LENS_SKIP_NATIVE_CHECKS:-0}" == 1 ]] && NATIVE_CHECKS=0
while (($#)); do
    case "$1" in
        --skip-native-checks) NATIVE_CHECKS=0 ;;
        -h | --help)
            printf 'Usage: %s <version> [--skip-native-checks]\n' "$0"
            exit 0
            ;;
        -*) die "Unknown option: $1" ;;
        *)
            [[ -z "$VERSION" ]] || die "Only one version can be given."
            VERSION="${1#v}"
            ;;
    esac
    shift
done
[[ -n "$VERSION" ]] || die "Usage: $0 <version>   (for example: $0 0.2.1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must look like 1.2.3 (got '$VERSION')."

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$VERSION" == "$PLIST_VERSION" ]] ||
    die "Version $VERSION doesn't match Resources/Info.plist ($PLIST_VERSION). Update CFBundleShortVersionString (and bump CFBundleVersion) first."

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "The working tree has uncommitted changes; the release will include them but the v$VERSION tag won't."
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
    warn "Tag v$VERSION already exists locally."
fi

step "Running LensCore tests"
swift run --quiet LensCoreTests

step "Running native offscreen checks"
if ((!NATIVE_CHECKS)); then
    warn "Skipped (--skip-native-checks)."
elif [[ "$(launchctl managername 2>/dev/null || true)" != Aqua ]]; then
    warn "Skipped: no logged-in GUI session to run AppKit checks in."
else
    swift build --quiet
    .build/debug/MacOSLens --self-test-native
fi

step "Packaging"
bash scripts/package.sh

ZIP="dist/macOS-Lens-$VERSION.zip"
DMG="dist/macOS-Lens-$VERSION.dmg"
LATEST_DMG="dist/macOS-Lens.dmg"
for file in "$ZIP" "$DMG" "$LATEST_DMG" dist/SHA256SUMS; do
    [[ -f "$file" ]] || die "Packaging didn't produce $file."
done
cmp -s "$DMG" "$LATEST_DMG" || die "$LATEST_DMG differs from $DMG."
ARCHS="$(lipo -archs ".build/package/macOS Lens.app/Contents/MacOS/MacOSLens")"
if [[ "$ARCHS" == *x86_64* ]]; then
    PLATFORMS="Universal app for Apple silicon and Intel Macs"
else
    PLATFORMS="Apple silicon only (this build has no Intel slice)"
fi
# Ask the files, not the environment: only a stapled disk image opens without the Gatekeeper prompt.
if xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
    FIRST_LAUNCH="The app is signed with a Developer ID and notarized by Apple, so it opens without a warning."
else
    FIRST_LAUNCH="The app is ad-hoc signed, so the first launch needs System Settings › Privacy & Security › Open Anyway."
fi
NOTES="dist/release-notes.md"
cat >"$NOTES" <<EOF
$PLATFORMS, running macOS 14 or newer. No Xcode needed.

Install or update:
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash

Or open macOS-Lens-$VERSION.dmg and drag macOS Lens to Applications. $FIRST_LAUNCH

Checksums are in SHA256SUMS.
EOF

step "Ready to publish macOS Lens $VERSION ($ARCHS)"
cat <<EOF
Before publishing, commit and push the version bump and Casks/macos-lens.rb (its sha256 now matches
$ZIP). Upload exactly these files: running package.sh again produces a different zip. Keep the asset
names: the in-app updater looks for macOS-Lens-$VERSION.zip and SHA256SUMS, and macOS-Lens.dmg keeps
https://github.com/$REPO/releases/latest/download/macOS-Lens.dmg pointing at the newest disk image.

Then run:

gh release create v$VERSION $ZIP $DMG $LATEST_DMG dist/SHA256SUMS --repo $REPO --title 'macOS Lens $VERSION' --notes-file $NOTES
EOF
