# Homebrew cask template for "AI Usage Monitor".
#
# NOTE: this cask was renamed from "usage-monitor-for-claude". The tap carries a
# `cask_renames.json` mapping the old token to this one so existing installs
# migrate on `brew update`; keep that entry as long as anyone might still be on it.
#
# For your own tap (no notability requirement — works from day one):
#   1. Create a repo named `homebrew-tap` on your GitHub account.
#   2. Put this file at `Casks/ai-usage-monitor.rb` in that repo.
#   3. Fill in `version` and `sha256` from a release built by
#      `tools/build_release.sh` (it prints the sha256).
#   4. Users install with:
#        brew tap stavrop/tap
#        brew install --cask ai-usage-monitor
#
# To later graduate into the official homebrew-cask, the app must be signed +
# notarized (it is, via build_release.sh) and the repo must meet Homebrew's
# notability threshold — roughly 75 stars (or comparable forks/watchers). See
# https://docs.brew.sh/Acceptable-Casks#rejected-casks
cask "ai-usage-monitor" do
  version "0.2.3"
  sha256 "85bfbf1ef9c60481b3859e749cee44953952228a43020f77a408051305c781cd"

  url "https://github.com/stavrop/ai-usage-monitor/releases/download/v#{version}/ClaudeUsage.zip"
  name "AI Usage Monitor"
  desc "Menu bar app showing Claude and ChatGPT usage limits"
  homepage "https://github.com/stavrop/ai-usage-monitor"

  depends_on macos: :monterey

  app "ClaudeUsage.app"

  zap trash: [
    "~/Library/Caches/com.local.claudeusage",
    "~/Library/HTTPStorages/com.local.claudeusage",
  ]
end
