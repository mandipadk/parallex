# Homebrew formula for the Parallex CLI. Until there's a tagged release and a
# tap, install the development head:
#
#   brew install --HEAD --build-from-source ./Formula/parallex.rb
#
# Once published in a tap (e.g. github.com/mandipadk/homebrew-parallex):
#
#   brew install mandipadk/parallex/parallex
class Parallex < Formula
  desc "Run multiple isolated instances of any macOS app"
  homepage "https://github.com/mandipadk/parallex"
  head "https://github.com/mandipadk/parallex.git", branch: "main"
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
