class AiBarracks < Formula
  desc "Git-native AI agent workspace with session tracking and persistent memory"
  homepage "https://github.com/ai-barracks/ai-barracks"
  url "https://github.com/ai-barracks/ai-barracks/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "a00a51ecbfff660b14e94710d2188b8684dda9e1dfbaeaf7329c8e3bb8665c82"
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
