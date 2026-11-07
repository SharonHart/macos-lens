# Building

Requires macOS 14 or newer and the Xcode Command Line Tools with Swift 5.10 or newer.

```sh
swift run LensCoreTests
swift build
.build/debug/MacOSLens --self-test-native
bash scripts/build-app.sh
open "dist/macOS Lens.app"
```

The build script creates an ad-hoc-signed application in `dist/`. Distribution to
other machines requires your own Developer ID signing and notarization.

The dependency-free test executable works with Command Line Tools installations
that do not include XCTest.
