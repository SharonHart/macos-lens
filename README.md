# Install

macOS Lens runs on macOS 14 Sonoma or newer, on Apple silicon and Intel Macs. Releases are prebuilt:
nothing to compile.

Once installed, updates come through **Check for Updates…** in the menu-bar menu (it also checks
GitHub's releases anonymously once a day; turn that off in Settings).

## One-line install

```sh
curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/install.sh | bash
```

The installer downloads the latest release, checks its SHA-256 checksum and code signature, installs
it to `/Applications` (or `~/Applications` when `/Applications` isn't writable), and opens it. Run it
again to update. Options such as `--no-launch` or `--dir <path>` go after `bash -s --`.

## Disk image

Download [macOS-Lens.dmg](https://github.com/SharonHart/macos-lens/releases/latest/download/macOS-Lens.dmg)
from the [latest release](https://github.com/SharonHart/macos-lens/releases/latest), open it, and drag
**macOS Lens** onto **Applications**. Releases aren't notarized, so the first launch shows
**“macOS Lens” Not Opened** (“Apple could not verify…”). Click **Done**, not **Move to Trash**, then open
System Settings › Privacy & Security and click **Open Anyway** next to the macOS Lens message. That
button stays for about an hour after the blocked launch; if it's gone, open the app again. This is
needed once per downloaded version.

## Homebrew

```sh
brew tap SharonHart/macos-lens https://github.com/SharonHart/macos-lens
brew trust --tap sharonhart/macos-lens   # Homebrew 7 and newer only load taps you trust
brew install --cask macos-lens
```

Homebrew quarantines its downloads, so the first launch shows the same dialog: click **Done**, then
**Open Anyway** as described above.

## First launch and Screen Recording

The first launch shows one window. Click **Allow Screen Recording…**: macOS asks once, then turn
macOS Lens on in System Settings › Privacy & Security › Screen & System Audio Recording and choose
**Quit & Reopen**. Nothing asks for permission until you click that button. If capturing still fails,
choose **Fix Screen Recording permission…** in the menu bar, the launcher or Settings; it clears the
app's stale entry and asks again.

Press Command + Shift + 2 to open the lens. Nothing is selected or sent until you circle, box or tap
something to search it; highlight, tap or circle text to select it. Command + Shift + 1 opens it with all the screen's text selected
(Control + Shift + 1 or Control + Option + T when macOS already uses it). Change both in Settings, or
set either to None and open the lens from the menu-bar icon.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/SharonHart/macos-lens/main/scripts/uninstall.sh | bash
```

This quits and removes the app, deletes its settings, caches and web data after asking, and resets its
privacy permissions. Add `-s -- --keep-data` after `bash` to keep the data, or `-s -- -y` to skip the
question. For Homebrew installs, run `brew uninstall --cask --zap macos-lens`.

## Signing

Releases are ad-hoc signed, and each build counts as a new app for Screen Recording, so after updating
the app shows its Screen Recording window again and you allow it once more. Signing with a Developer ID certificate
and notarizing would remove the Gatekeeper warning and keep the Screen Recording permission across
updates.

Development and release notes are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

[![Buy Me A Coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=sharonhart&button_colour=FFDD00&font_colour=000000&font_family=Inter&outline_colour=000000&coffee_colour=ffffff)](https://buymeacoffee.com/sharonhart)
