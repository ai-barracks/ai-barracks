class MultiAiPlatform < Formula
  desc "Cross-client LLM session sharing and persistent memory system"
  homepage "https://github.com/CYRok90/multi-ai-platform"
  url "https://github.com/CYRok90/multi-ai-platform/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "8b5f8407ad277dd4441f66d19c9d3eecdcc302ac8c6667e6966215b1f4d3e69d"
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
