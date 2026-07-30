# Homebrew formula for herdr-extensions. This repo is its own tap:
#
#   brew tap vonzelle-vzt/herdr-extensions https://github.com/vonzelle-vzt/herdr-extensions
#   brew install vonzelle-vzt/herdr-extensions/herdr-extensions
#
# The README documented exactly that for a long time while this file did not exist, so the tap
# succeeded and the install failed with "No available formula or cask". Formula/ must exist in the
# repo being tapped -- that is the whole mechanism.
class HerdrExtensions < Formula
  desc "Turn herdr into a terminal IDE: editor, LSP diagnostics, panels, live preview"
  homepage "https://github.com/vonzelle-vzt/herdr-extensions"
  url "https://github.com/vonzelle-vzt/herdr-extensions/archive/refs/tags/v0.10.0.tar.gz"
  sha256 "e5db5cd2ec3a6b2fe52db683a53bb17f10a24d8a53a830d40d209b757ee8909b"
  license "MIT"

  # Stdlib-only Python 3.9+, which is what macOS ships -- so no python dependency is declared and
  # no virtualenv is created. herdr itself is intentionally not a dependency: `herdr-extensions
  # doctor` reports a missing or too-old herdr far more usefully than brew resolution would.
  depends_on "lazygit" => :recommended

  def install
    libexec.install "bin", "plugin", "libexec", "skins"
    # A SYMLINK, not a shell shim. The CLI resolves its package root with
    # realpath(__file__), so a symlink lands on libexec correctly -- and the shim this
    # replaced was mangled through two layers of heredoc escaping into `exec "..." "\"`,
    # which silently swallowed every argument.
    bin.install_symlink libexec/"bin/herdr-extensions"
    doc.install "README.md", "SPEC.md", "UPSTREAM.md", "CLAUDE.md"
  end

  def caveats
    <<~EOS
      Finish setup with:
        herdr-extensions install

      That installs the editor (herdr-edit), a Nerd Font and prettier if missing,
      registers the panels, and injects keybindings checked against herdr's own.
      Then verify with:
        herdr-extensions doctor
    EOS
  end

  test do
    assert_match "herdr-extensions", shell_output("#{bin}/herdr-extensions --help 2>&1")
  end
end
