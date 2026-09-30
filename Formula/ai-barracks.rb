class AiBarracks < Formula
  desc "Git-native AI agent workspace with session tracking and persistent memory"
  homepage "https://github.com/ai-barracks/ai-barracks"
  url "https://github.com/ai-barracks/ai-barracks/archive/refs/tags/v1.3.4.tar.gz"
  sha256 "0f0f69d5fd885521fdb4c8fe2f8e8b4d5cfca401fbb5fea2a7d0546e09037efb"
  license "MIT"

  depends_on "jq"

  def install
    bin.install "bin/aib"
    pkgshare.install "templates"
    pkgshare.install "scripts"
    zsh_completion.install "completions/_aib"

    # Patch template dir path in the aib script
    inreplace bin/"aib", /^TEMPLATE_DIR=.*$/, "TEMPLATE_DIR=\"#{pkgshare}/templates\""
  end

  test do
    system bin/"aib", "version"
    ENV["AIB_REGISTRY"] = (testpath/"registry.json").to_s
    ENV["AIB_CLAUDE_SETTINGS"] = (testpath/"claude-settings.json").to_s
    ENV["AIB_GEMINI_SETTINGS"] = (testpath/"gemini-settings.json").to_s
    system bin/"aib", "init", testpath/"fixture"
    system bin/"aib", "sync", testpath/"fixture", "--dry-run"
    assert_path_exists testpath/"fixture/agent.yaml"
  end
end
