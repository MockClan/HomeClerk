# Homebrew cask for HomeClerk. This repository is its own tap; each release updates the version and
# sha256 below (see .github/workflows/release.yml).
#
# Install:
#   brew tap mockclan/homeclerk https://github.com/MockClan/HomeClerk
#   brew trust mockclan/homeclerk
#   brew install --cask homeclerk

cask "homeclerk" do
  version "1.0.0"
  sha256 "4fc21c4ff036af228a758b3d181ffc1c1fecdf8498e69e3db2d67aeb39de13ad"

  url "https://github.com/MockClan/HomeClerk/releases/download/v#{version}/HomeClerk-v#{version}-osx-arm64.zip"
  name "HomeClerk"
  desc "Household document organizer that files scans by reading them with AI"
  homepage "https://github.com/MockClan/HomeClerk"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "HomeClerk.app"

  # Upgrades and uninstalls quit the app first
  uninstall quit: "com.mockclan.homeclerk"

  # Only the app's preferences — never ~/HomeClerk, which holds your documents
  zap trash: "~/Library/Preferences/com.mockclan.homeclerk.plist"

  caveats <<~EOS
    HomeClerk isn't signed with an Apple Developer ID, so macOS blocks its first launch after each
    install or upgrade. Open HomeClerk from Applications, then choose "Open Anyway" in
    System Settings > Privacy & Security. On its first run, HomeClerk's Setup Assistant walks
    through the rest.
  EOS
end
