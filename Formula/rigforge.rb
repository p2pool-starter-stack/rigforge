class Rigforge < Formula
  desc "Provision and run a tuned XMRig worker for RandomX mining"
  homepage "https://github.com/p2pool-starter-stack/rigforge"
  url "https://github.com/p2pool-starter-stack/rigforge/releases/download/v1.19.0/rigforge-v1.19.0.tar.gz"
  sha256 "429af53f592eeeba88aa9a608467f14b975d76042305a2379159777dff4310bc"
  license "MIT"

  depends_on "bash"
  depends_on "flock"
  depends_on "jq"

  def install
    libexec.install Dir["*"]
    (libexec/".rigforge-package").write "brew\n"
    (bin/"rigforge").write_env_script libexec/"rigforge.sh",
      PATH:                 "#{formula_opt_bin("bash")}:#{formula_opt_bin("jq")}:#{formula_opt_bin("flock")}:$PATH",
      RIGFORGE_CONFIG_META: "#{var}/rigforge-config-meta.json"
  end

  def caveats
    <<~EOS
      Installing does nothing to this machine. Configure and provision explicitly:
        cp #{opt_libexec}/config.minimal.json #{opt_libexec}/config.json
        sudo rigforge setup
      config.json lives in the installed tree and a brew upgrade replaces that tree: run
      `rigforge backup` first and `rigforge restore` afterwards. A running miner is never
      restarted automatically; run `sudo rigforge apply` yourself after reviewing the release notes.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rigforge --version")
  end
end
