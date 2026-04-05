class MultiAiPlatform < Formula
  desc "Cross-client LLM session sharing and persistent memory system"
  homepage "https://github.com/choihouse/multi-ai-platform"
  url "https://github.com/choihouse/multi-ai-platform/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "" # TODO: fill after first release
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
