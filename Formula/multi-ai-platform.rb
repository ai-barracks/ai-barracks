class MultiAiPlatform < Formula
  desc "Cross-client LLM session sharing and persistent memory system"
  homepage "https://github.com/CYRok90/multi-ai-platform"
  url "https://github.com/CYRok90/multi-ai-platform/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "03afba867034445385f631acd1b070dcce3e381bb749664498899381f9729378"
  license "MIT"

  def install
    bin.install "bin/map"
    pkgshare.install "templates"
    pkgshare.install "scripts"

    # Patch template dir path in the map script
    inreplace bin/"map", /^TEMPLATE_DIR=.*$/, "TEMPLATE_DIR=\"#{pkgshare}/templates\""
  end

  test do
    system bin/"map", "version"
  end
end
