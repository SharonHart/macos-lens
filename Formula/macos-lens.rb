class MacosLens < Formula
  desc "Select part of the screen to search it with Google Lens or copy its text"
  homepage "https://github.com/SharonHart/macos-lens"
  head "https://github.com/SharonHart/macos-lens.git", branch: "main"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"

    app = prefix/"macOS Lens.app"
    (app/"Contents/MacOS").install ".build/release/MacOSLens"
    (app/"Contents").install "Resources/Info.plist"
    system "codesign", "--force", "--sign", "-", "--identifier", "dev.macos-lens.client", app

    (bin/"macos-lens").write <<~SH
      #!/bin/bash
      # Opens macOS Lens. --install copies it to /Applications (or ~/Applications) first, so the
      # Screen Recording permission sticks to a stable location.
      set -euo pipefail
      SOURCE="#{opt_prefix}/macOS Lens.app"

      case "${1:-}" in
        --install)
          if [[ -w /Applications ]]; then dir=/Applications; else dir="$HOME/Applications"; mkdir -p "$dir"; fi
          target="$dir/macOS Lens.app"
          # Quit only a copy running from the target path, never other copies.
          ps -axo pid=,command= | while read -r pid command; do
            if [[ "$command" == "$target/Contents/MacOS/"* ]]; then kill "$pid" 2>/dev/null || true; fi
          done
          sleep 1
          rm -rf "$target"
          ditto "$SOURCE" "$target"
          # Each ad-hoc signed build counts as a new app; clear only this app's stale Screen Recording entry.
          /usr/bin/tccutil reset ScreenCapture dev.macos-lens.client >/dev/null 2>&1 || true
          echo "Installed $target"
          open "$target"
          ;;
        -h|--help)
          echo "Usage: macos-lens [--install]"
          echo "  --install  copy macOS Lens to /Applications (or ~/Applications) and open it"
          ;;
        *)
          for dir in /Applications "$HOME/Applications"; do
            if [[ -d "$dir/macOS Lens.app" ]]; then exec open "$dir/macOS Lens.app"; fi
          done
          exec open "$SOURCE"
          ;;
      esac
    SH
    chmod 0755, bin/"macos-lens"
  end

  def caveats
    <<~EOS
      macOS Lens was built into:
        #{opt_prefix}/macOS Lens.app

      Screen Recording permission is tied to the app's location and signature, so copy it to
      /Applications (or ~/Applications) and open it from there:
        macos-lens --install

      Run `macos-lens --install` again after `brew upgrade --fetch-HEAD macos-lens`.
    EOS
  end

  test do
    app = prefix/"macOS Lens.app"
    plist = app/"Contents/Info.plist"
    assert_equal "dev.macos-lens.client",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '#{plist}'").chomp
    system "codesign", "--verify", "--deep", "--strict", app
  end
end
