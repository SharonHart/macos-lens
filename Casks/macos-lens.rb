# version and sha256 are rewritten by scripts/package.sh so they always match the packaged zip.
cask "macos-lens" do
  version "0.2.2"
  sha256 "4beaf9445065acb10d481a8e3adb9b15f6c60aab5497ad18464ab913dc5a0be6"

  url "https://github.com/SharonHart/macos-lens/releases/download/v#{version}/macOS-Lens-#{version}.zip"
  name "macOS Lens"
  desc "Select part of the screen to search it with Google Lens or copy its text"
  homepage "https://github.com/SharonHart/macos-lens"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "macOS Lens.app"

  uninstall quit: "dev.macos-lens.client"

  zap trash: [
    "~/Library/Caches/dev.macos-lens.client",
    "~/Library/HTTPStorages/dev.macos-lens.client*",
    "~/Library/Preferences/dev.macos-lens.client.plist",
    "~/Library/Saved Application State/dev.macos-lens.client.savedState",
    "~/Library/WebKit/dev.macos-lens.client",
  ]
end
