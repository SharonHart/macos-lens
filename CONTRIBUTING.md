# Contributing

## Building

Requires macOS 14 or newer and the Xcode Command Line Tools with Swift 5.10 or newer.

```sh
swift run LensCoreTests
swift build
.build/debug/MacOSLens --self-test-native [snapshot.png]   # offscreen overlay checks; optional renders
.build/debug/MacOSLens --panel-aspect-check <folder>       # offscreen results-sheet image shape, sample strips
bash scripts/build-app.sh
open "dist/macOS Lens.app"
```

Optional network checks upload only a generated test image, never screen content,
to Google Lens's undocumented upload endpoint:

```sh
.build/debug/MacOSLens --integration-fixture
.build/debug/MacOSLens --panel-check
LENS_VISIBLE=1 .build/debug/MacOSLens --panel-aspect-check <folder> live   # nearly transparent window
.build/debug/MacOSLens --overlay-check   # briefly shows the overlay on the main display
```

The build script creates an ad-hoc-signed application in `dist/`. Distribution to
other machines requires your own Developer ID signing and notarization.

The dependency-free test executable works with Command Line Tools installations
that do not include XCTest.

The build script resets this app's own Screen Recording entry, because each ad-hoc
signature counts as a new app. After launching, turn macOS Lens on in
System Settings › Privacy & Security › Screen & System Audio Recording, or use
**Fix Screen Recording permission** in the app. Set `MACOS_LENS_SKIP_TCC_RESET=1` to skip the reset.

## Releasing

```sh
./scripts/release.sh 0.2.0
```

The version must match `CFBundleShortVersionString` in `Resources/Info.plist`. The script runs the
tests and native checks, then `scripts/package.sh`, which builds a universal (arm64 and x86_64) app and
writes `dist/macOS-Lens-<version>.zip`, `dist/macOS-Lens-<version>.dmg` and `dist/SHA256SUMS`, and
updates the version and checksum in `Casks/macos-lens.rb`. It prints the `gh release create` command
to run; commit the updated cask first.
