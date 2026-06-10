# Homebrew formula for the Parallex CLI. Until the project has a public
# GitHub repo + tagged release, install from the local checkout:
#
#   brew install --HEAD --build-from-source ./Formula/parallex.rb
#
# Once the repo is published, update `head`/`url` and move this into a tap
# (e.g. github.com/<user>/homebrew-parallex) so it becomes:
#
#   brew install <user>/parallex/parallex
class Parallex < Formula
  desc "Run multiple isolated instances of any macOS app"
  homepage "https://github.com/REPLACE-ME/parallex"
  head "https://github.com/REPLACE-ME/parallex.git", branch: "main"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/parallex"
    bin.install ".build/release/parallex-launcher"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/parallex --version") if build.stable?
    system bin/"parallex", "--help"
  end
end
