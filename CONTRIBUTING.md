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

The app icon, `Contents/Resources/AppIcon.icns`, is drawn at build time by `scripts/dmg/DMGArt.swift`
(`dmg-art icon`) from the app's `LensMark.swift` and packed with `iconutil`, so it always matches the
mark. It follows Apple's icon grid, so macOS 26 shows it without a grey container. The result is cached
in `.build/app-icon/`, keyed by both sources.

The dependency-free test executable works with Command Line Tools installations
that do not include XCTest.

Each ad-hoc signature counts as a new app for Screen Recording. The scripts never touch
privacy settings: after launching a new build, click **Allow Screen Recording…** in its window
(or **Fix Screen Recording permission…**), which clears the app's own stale entry and asks macOS once.

## Releasing

Signed releases come from the **Release** workflow (see [Signed releases](#signed-releases)). To
build a release on your own Mac instead:

```sh
./scripts/release.sh 0.2.1
```

The version must match `CFBundleShortVersionString` in `Resources/Info.plist`. The script runs the
tests and native checks, then `scripts/package.sh`, which builds a universal (arm64 and x86_64) app and
writes `dist/macOS-Lens-<version>.zip`, `dist/macOS-Lens-<version>.dmg`, a version-less copy
`dist/macOS-Lens.dmg` (so `releases/latest/download/macOS-Lens.dmg` always resolves) and
`dist/SHA256SUMS`, and
updates the version and checksum in `Casks/macos-lens.rb`. It writes the release notes to
`dist/release-notes.md` and prints the `gh release create` command to run; commit the updated cask first.

The disk images come from `scripts/make-dmg.sh`, which `package.sh` calls. Run it on its own to
rebuild the disk images and `SHA256SUMS` from the existing zip, without a new zip or cask change. It
never uses Finder or AppleScript, so it runs headless:

- The window background is drawn by `scripts/dmg/DMGArt.swift`, compiled together with
  `Sources/MacOSLens/LensMark.swift` so the mark can't drift. The wordmark font is
  `scripts/dmg/Urbanist-Variable.ttf` (SIL Open Font License, `scripts/dmg/OFL-Urbanist.txt`).
  The volume icon is the app's own `AppIcon.icns`.
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

## Signed releases

`.github/workflows/release.yml` signs the app and the disk image with a Developer ID certificate and
has Apple notarize both, so they open without the Gatekeeper warning and keep their Screen Recording
permission across updates. It runs `scripts/release.sh` on a `macos-26` runner, then publishes the
release and points `Casks/macos-lens.rb` on `main` at the new zip.

### Set up once

You need a paid Apple Developer Program membership.

1. In [Certificates, IDs & Profiles](https://developer.apple.com/account/resources/certificates/list),
   create a **Developer ID Application** certificate. In Keychain Access, export it with its private
   key as a `.p12` file with a password.
2. In [App Store Connect › Users and Access › Integrations](https://appstoreconnect.apple.com/access/integrations/api),
   create a **Team** API key with the **Developer** role. Download the `.p8` file (you can only do this
   once), and note the key ID and the issuer ID.
3. Store them in the repository's `release` environment. Secrets go into GitHub, never into the
   repository:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
   gh secret set DEVELOPER_ID_P12_PASSWORD --env release
   base64 -i AuthKey_ABCDE12345.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release
   gh variable set DEVELOPER_ID_IDENTITY --env release --body "Developer ID Application: Your Name (TEAMID1234)"
   gh variable set NOTARY_KEY_ID --env release --body ABCDE12345
   gh variable set NOTARY_ISSUER_ID --env release --body 00000000-0000-0000-0000-000000000000
   ```

   `security find-identity -v -p codesigning` shows the exact `DEVELOPER_ID_IDENTITY`. In Settings ›
   Environments › release, you can limit the environment to `main` and add yourself as a required
   reviewer, so every release waits for your approval.

### Release a version

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and merge it
   to `main`.
2. Do a dry run. It builds, signs and notarizes, and keeps the files on the run without publishing:

   ```sh
   gh workflow run release.yml -f version=0.2.2
   ```

3. When the dry run passes, publish:

   ```sh
   gh workflow run release.yml -f version=0.2.2 -f publish=true
   ```

   This tags `v0.2.2` at the run's commit, uploads the zip, both disk images and `SHA256SUMS`, and
   commits the new version and checksum to `Casks/macos-lens.rb`. A version that is already tagged
   is never replaced; release a new one.

The first signed release changes the app's signature, so people allow Screen Recording once more
after updating to it. After that the permission stays across updates.

To sign and notarize on your own Mac, save the API key in your keychain once:

```sh
xcrun notarytool store-credentials macos-lens --key AuthKey_ABCDE12345.p8 --key-id ABCDE12345 \
    --issuer 00000000-0000-0000-0000-000000000000
```

Then:

```sh
MACOS_LENS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
MACOS_LENS_NOTARY_PROFILE=macos-lens ./scripts/release.sh 0.2.2
```

`scripts/notarize.sh` prints Apple's submission ID before it waits. If Apple takes longer than 30
minutes, check that submission with `xcrun notarytool info <id>` instead of submitting again.
