# Source of truth for the cask in tietjen/homebrew-tap. After a release, copy this file over
# with the new version and sha256 (both are in build/release/<version>/SHA256SUMS).
#
#   brew install --cask tietjen/tap/mailkeeper
#
# Not in homebrew/cask (yet): that repository has notability requirements, and a tap of our own
# can be updated from the release workflow. Nothing about this file would have to change.
cask "mailkeeper" do
  # Both lines are filled in from build/release/<version>/SHA256SUMS at release time. The
  # placeholder below is deliberately not a valid hash, so a copy made by accident fails loudly.
  version "0.1.0"
  sha256 "PLATZHALTER-aus-SHA256SUMS-eintragen"

  url "https://github.com/tietjen/mailkeeper/releases/download/v#{version}/MailKeeper-#{version}.dmg"
  name "MailKeeper"
  desc "Mailarchiv für macOS mit Suche, Aufräumhilfe und lokaler KI"
  homepage "https://github.com/tietjen/mailkeeper"

  livecheck do
    url :url
    strategy :github_latest
  end

  # MailKeeper updates itself through Sparkle. Without this, `brew upgrade` and Sparkle would
  # both replace the app and fight over it; with it, Homebrew leaves the app alone and only
  # `brew upgrade --greedy` touches it.
  auto_updates true

  depends_on macos: ">= :tahoe"

  app "MailKeeper.app"

  # No zap on purpose.
  #
  # MailKeeper is sandboxed: settings, logs and the default archive all live in
  # ~/Library/Containers/de.paranoidsecurity.MailKeeper/. Removing that folder would take the
  # mail with it — often the only copy left after the server was cleaned up. A package manager
  # must not do that because someone uninstalled the app to try something out. The paths
  # outside the container (~/Library/Preferences/…, ~/Library/Logs/MailKeeper) do not exist
  # for the sandboxed build, so listing them would only pretend to clean up.

  caveats <<~EOS
    Beim Deinstallieren bleiben deine Daten erhalten — auch mit `--zap`. Sie liegen in
      ~/Library/Containers/de.paranoidsecurity.MailKeeper/
    bzw. in dem Ordner, den du selbst als Archiv gewählt hast, und enthalten deine Mails.
    Lösche sie von Hand, wenn du sie wirklich loswerden willst.
  EOS
end
