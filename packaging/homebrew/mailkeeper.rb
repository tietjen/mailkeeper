# Source of truth for the cask in tietjen/homebrew-tap. After a release, copy this file over
# with the new version and sha256 (both are in build/release/<version>/SHA256SUMS).
#
#   brew install --cask tietjen/tap/mailkeeper
#
# Not in homebrew/cask (yet): that repository has notability requirements, and a tap of our own
# can be updated from the release workflow. Nothing about this file would have to change.
cask "mailkeeper" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/tietjen/mailkeeper/releases/download/v#{version}/MailKeeper-#{version}.dmg",
      verified: "github.com/tietjen/mailkeeper/"
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

  # `brew uninstall --zap` deliberately does NOT remove the archive.
  #
  # The archive holds the user's mail — often the only copy left after the server was cleaned
  # up. A package manager must not delete that because someone uninstalled the app to try
  # something out. Settings, logs and caches go; the mail stays, and the user deletes the
  # folder themselves when they mean it.
  zap trash: [
    "~/Library/Preferences/de.paranoidsecurity.MailKeeper.plist",
    "~/Library/Logs/MailKeeper",
    "~/Library/Caches/de.paranoidsecurity.MailKeeper",
    "~/Library/Saved Application State/de.paranoidsecurity.MailKeeper.savedState",
  ]

  caveats <<~EOS
    Das Archiv (Standard: im Container der App, sonst der selbst gewählte Ordner) bleibt beim
    Deinstallieren erhalten — auch bei `--zap`. Es enthält deine Mails; lösche es von Hand,
    wenn du es wirklich loswerden willst.
  EOS
end
