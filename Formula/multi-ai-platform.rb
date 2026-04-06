class MultiAiPlatform < Formula
  desc "Cross-client LLM session sharing and persistent memory system"
  homepage "https://github.com/CYRok90/multi-ai-platform"
  url "https://github.com/CYRok90/multi-ai-platform/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "e8891f0314980a0a19276f673553a4ff1d1d87f7e278cd3f2272cb224335e4b5"
  license "MIT"

  def install
    bin.install "bin/map"
    pkgshare.install "templates"

    # Patch template dir path in the map script
    inreplace bin/"map", /^TEMPLATE_DIR=.*$/, "TEMPLATE_DIR=\"#{pkgshare}/templates\""
  end

  test do
    system bin/"map", "version"
  end
end
