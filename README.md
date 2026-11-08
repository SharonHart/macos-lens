# Building

Requires macOS 14 or newer and the Xcode Command Line Tools with Swift 5.10 or newer.

```sh
swift run LensCoreTests
swift build
.build/debug/MacOSLens --self-test-native [snapshot.png]   # offscreen overlay checks; optional renders
bash scripts/build-app.sh
open "dist/macOS Lens.app"
```

Optional network checks upload only a generated test image, never screen content,
to Google Lens's undocumented upload endpoint:

```sh
.build/debug/MacOSLens --integration-fixture
.build/debug/MacOSLens --panel-check
.build/debug/MacOSLens --overlay-check   # briefly shows the overlay on the main display
```

The build script creates an ad-hoc-signed application in `dist/`. Distribution to
other machines requires your own Developer ID signing and notarization.

The dependency-free test executable works with Command Line Tools installations
that do not include XCTest.
