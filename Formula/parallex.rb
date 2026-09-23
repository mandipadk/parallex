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
    # Universal, so copies of Intel apps (and tools they start under
    # Rosetta) can load the home-redirect library.
    system "swift", "build", "-c", "release", "--disable-sandbox", "--arch", "arm64", "--arch", "x86_64"
    products = Utils.safe_popen_read("swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64",
                                     "--show-bin-path").strip
    bin.install "#{products}/parallex"
    bin.install "#{products}/parallex-launcher"
    bin.install "#{products}/parallex-router"
    libexec.install "#{products}/libparallexhome.dylib"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/parallex --version") if build.stable?
    system bin/"parallex", "--help"
  end
end
