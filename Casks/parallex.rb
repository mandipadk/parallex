# Parallex as an app, from its GitHub releases:
#
#   brew tap mandipadk/parallex https://github.com/mandipadk/parallex
#   brew install --cask parallex
#
# `make cask` updates the version and checksum after a release.
cask "parallex" do
  version "1.8.0"
  sha256 "fc88fdb4260c86d6ab5f5adb4db2ceaaeffd1e6e1abde0c3e255ec8801ad4e6c"

  url "https://github.com/mandipadk/parallex/releases/download/v#{version}/Parallex-#{version}.zip"
  name "Parallex"
  desc "Run separate instances of apps side by side"
  homepage "https://parallex.mandip.dev/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Parallex updates itself (signed updates, checked against its own key).
  auto_updates true
  depends_on macos: :sonoma

  app "Parallex.app"
  binary "#{appdir}/Parallex.app/Contents/Resources/parallex"

  # Parallex isn't notarized yet, so macOS would stop it on first open and
  # send you to System Settings › Open Anyway. The download is checked
  # against the checksum above instead, as the Terminal installer does.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Parallex.app"]
  end

  # Only Parallex's own settings: your instances and their data are kept.
  zap trash: [
    "~/Library/Caches/com.parallex.app",
    "~/Library/Preferences/com.parallex.app.plist",
  ]

  caveats <<~EOS
    Before uninstalling, turn off link routing in Parallex › Settings › Links,
    so your default browser and sign-in links go back to the apps you had.
  EOS
end
