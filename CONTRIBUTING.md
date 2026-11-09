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

Each ad-hoc signature counts as a new app for Screen Recording. The scripts never touch
privacy settings: after launching a new build, click **Allow Screen Recording…** in its window
(or **Fix Screen Recording permission…**), which clears the app's own stale entry and asks macOS once.

## Releasing

```sh
./scripts/release.sh 0.2.1
```

The version must match `CFBundleShortVersionString` in `Resources/Info.plist`. The script runs the
tests and native checks, then `scripts/package.sh`, which builds a universal (arm64 and x86_64) app and
writes `dist/macOS-Lens-<version>.zip`, `dist/macOS-Lens-<version>.dmg`, a version-less copy
`dist/macOS-Lens.dmg` (so `releases/latest/download/macOS-Lens.dmg` always resolves) and
`dist/SHA256SUMS`, and
updates the version and checksum in `Casks/macos-lens.rb`. It prints the `gh release create` command
to run; commit the updated cask first.

The disk images come from `scripts/make-dmg.sh`, which `package.sh` calls. Run it on its own to
rebuild the disk images and `SHA256SUMS` from the existing zip, without a new zip or cask change. It
never uses Finder or AppleScript, so it runs headless:

- The window background and volume icon are drawn by `scripts/dmg/DMGArt.swift`, compiled together
  with `Sources/MacOSLens/LensMark.swift` so the mark can't drift. The wordmark font is
  `scripts/dmg/Urbanist-Variable.ttf` (SIL Open Font License, `scripts/dmg/OFL-Urbanist.txt`).
- The Finder layout is written into the image's `.DS_Store` by
  [dmgbuild](https://github.com/dmgbuild/dmgbuild), with `ds-store` and `mac-alias`, all pinned by
  hash in `scripts/dmg/requirements.txt`. They are installed into a venv under
  `~/Library/Caches/macos-lens`, which needs Python 3.9 or later (set `PYTHON` to choose one) and the
  network on the first run.
- `scripts/dmg/build.py` mounts the writable image at a private directory instead of `/Volumes`,
  because endpoint data-loss-prevention agents can block unmounting a written volume there.
- The finished image is checked mounted read-only at `/Volumes/macOS Lens`, so eject any volume of
  that name first. Set `MACOS_LENS_DMG_QA=<dir>` to also write light and dark previews of the window
  and a dump of the `.DS_Store` there.

The in-app updater reads the latest published release and needs its assets named exactly
`macOS-Lens-X.Y.Z.zip` and `SHA256SUMS`, with a tag of `vX.Y.Z` matching the app's version. Keep those
names, or installed copies can no longer update themselves.
