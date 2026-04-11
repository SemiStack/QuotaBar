cask "quotabar" do
  version :latest
  sha256 :no_check

  url "https://github.com/SemiStack/QuotaBar/releases/latest/download/QuotaBar-macOS.zip"
  name "QuotaBar"
  desc "macOS menu bar AI quota monitor for Copilot, Claude, Codex, and Gemini"
  homepage "https://github.com/SemiStack/QuotaBar"

  depends_on macos: ">= :sonoma"

  app "QuotaBar.app"

  zap trash: [
    "~/Library/Application Support/QuotaBar",
  ]
end
