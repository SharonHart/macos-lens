# Install

macOS Lens runs on macOS 14 Sonoma or newer, on Apple silicon and Intel Macs.

## One-line install (prebuilt, no Xcode needed)

```sh
curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/install.sh | bash
```

The installer downloads the latest release, checks its SHA-256 checksum and code signature, installs
it to `/Applications` (or `~/Applications` when `/Applications` isn't writable), and opens it. Run it
again to update. From a clone, run `./scripts/install.sh`. Options such as `--no-launch` or
`--dir <path>` go after `bash -s --` when piping.

While the repository is private, GitHub needs to know who you are: sign in with `gh auth login` (the
installer then downloads with `gh`) or set `GITHUB_TOKEN` to a token that can read the repository.
Fetch the script itself with `gh`, or run it from a clone:

```sh
gh api -H 'Accept: application/vnd.github.raw' repos/SharonHart/macos-lens/contents/scripts/install.sh | bash
```

## Disk image

Download `macOS-Lens-<version>.dmg` from
[Releases](https://github.com/SharonHart/macos-lens/releases), open it, and drag **macOS Lens** onto
**Applications**. Releases are ad-hoc signed rather than notarized, so macOS blocks the first launch:
open System Settings › Privacy & Security and click **Open Anyway** next to the macOS Lens message.
This is needed once per downloaded version.

## Homebrew

```sh
brew tap sharonhart/macos-lens https://github.com/SharonHart/macos-lens
brew trust sharonhart/macos-lens   # Homebrew 7+ only loads third-party taps you trust
brew install --cask sharonhart/macos-lens/macos-lens
```

The cask installs the prebuilt release and only works once the repository is public, because
Homebrew can't download private release assets. Homebrew quarantines its downloads, so use
**Open Anyway** once as described above.

The tap also has a formula that builds the latest source with the Command Line Tools (this works
while the repository is private if git can sign in to GitHub):

```sh
brew install --HEAD sharonhart/macos-lens/macos-lens
macos-lens --install   # copies the app to /Applications (or ~/Applications) and opens it
```

## Build from source

```sh
./scripts/install.sh --from-source
```

This needs the Xcode Command Line Tools with Swift 5.10 or newer; the installer starts
`xcode-select --install` when they're missing. Piped from `curl`, `bash -s -- --from-source` clones
the repository first (using your git credentials while it's private). The installer also builds from
source when no release has been published. See [Building](#building) for development builds.

## Uninstall

```sh
./scripts/uninstall.sh
```

This quits and removes the app, deletes its settings, caches and web data, and resets its privacy
permissions. `--keep-data` keeps the data and `-y` skips the confirmation. For Homebrew installs, run
`brew uninstall --cask --zap macos-lens` or `brew uninstall macos-lens`.

## First run

macOS Lens adds itself to System Settings › Privacy & Security › Screen & System Audio Recording.
Turn it on there, then choose **Quit & Reopen**. The default shortcuts are Command + Shift + 2 to
search the screen and Command + Shift + 1 to select text (Control + Shift + 1 or Control + Option + T
when macOS already uses it).

## Signing

Releases are ad-hoc signed, and each build counts as a new app for Screen Recording, so the installer
resets the old entry and you turn it on again after updating. Signing with a Developer ID certificate
and notarizing would remove the Gatekeeper warning and keep the Screen Recording permission across
updates.

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

## Support

[![Buy Me A Coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=sharonhart&button_colour=FFDD00&font_colour=000000&font_family=Inter&outline_colour=000000&coffee_colour=ffffff)](https://buymeacoffee.com/sharonhart)
