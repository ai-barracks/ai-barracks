class AiBarracks < Formula
  desc "Git-native AI agent workspace with session tracking and persistent memory"
  homepage "https://github.com/ai-barracks/ai-barracks"
  url "https://github.com/ai-barracks/ai-barracks/archive/refs/tags/v1.5.0.tar.gz"
  sha256 "9a436ab49a8f6513abb38f1ba0196fe63eeeff9d7022f248062cf72e5f49c73d"
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
    before_protocol = (testpath/"fixture/AGENTS.md").read
    before_agent = (testpath/"fixture/agent.yaml").read
    system bin/"aib", "sync", "--dry-run", testpath/"fixture"
    assert_equal before_protocol, (testpath/"fixture/AGENTS.md").read
    assert_equal before_agent, (testpath/"fixture/agent.yaml").read
    assert_path_exists testpath/"fixture/agent.yaml"
  end
end
