# Parallex as an app, from its GitHub releases:
#
#   brew tap mandipadk/parallex https://github.com/mandipadk/parallex
#   brew install --cask parallex
#
# `make cask` updates the version and checksum after a release.
cask "parallex" do
  version "0.22.0"
  sha256 "63aa2322438f80a611b57aa4f03a9c3c3f9bae4daf06a1a16297eeecc222c296"

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
