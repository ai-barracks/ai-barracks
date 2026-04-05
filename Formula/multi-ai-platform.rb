class MultiAiPlatform < Formula
  desc "Cross-client LLM session sharing and persistent memory system"
  homepage "https://github.com/CYRok90/multi-ai-platform"
  url "https://github.com/CYRok90/multi-ai-platform/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "20699d4c8f2e08fbf623306f4d930af2b1a40fbb2e30f75f0b9583c6d9b565e5"
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
