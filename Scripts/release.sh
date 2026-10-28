#!/bin/zsh
# One release of MailKeeper: checks, build, DMG, notarisation, Sparkle signature, appcast.
#
#   Scripts/release.sh 0.2.0              build and sign everything, publish nothing
#   Scripts/release.sh 0.2.0 --no-notarize   dry run without Apple (for trying things out)
#   Scripts/release.sh 0.2.0 --publish    additionally set the tag; CI builds the release
#
# Everything lands in build/release/<version>/: the app, the DMG, appcast.xml, SHA256SUMS.
#
# Credentials, never in the repo:
#   · Developer ID in the login keychain
#   · notarisation: keychain profile "MailKeeper", or APPLE_ID / APPLE_APP_PASSWORD /
#     APPLE_TEAM_ID in the environment (that is what CI uses)
#   · Sparkle: the private key from the login keychain (account "MailKeeper"), or
#     SPARKLE_ED_PRIVATE_KEY in the environment
set -euo pipefail
cd "${0:A:h}/.."

VERSION_ARG="${1:-}"
NOTARIZE=1 PUBLISH=0
for a in "${@:2}"; do
  case "$a" in
    --no-notarize) NOTARIZE=0 ;;
    --publish) PUBLISH=1 ;;
    *) echo "unbekannte Option: $a" >&2; exit 2 ;;
  esac
done
[[ -n "$VERSION_ARG" ]] || { sed -n '2,16p' "$0"; exit 2 }

# The signing material must not be inherited by swift test, the build, hdiutil or codesign —
# none of them needs it, and any one of them could print its environment.
SPARKLE_KEY="${SPARKLE_ED_PRIVATE_KEY:-}"
APPLE_PW="${APPLE_APP_PASSWORD:-}"
typeset +x SPARKLE_ED_PRIVATE_KEY APPLE_APP_PASSWORD 2>/dev/null || true
unset SPARKLE_ED_PRIVATE_KEY APPLE_APP_PASSWORD

APP_NAME="MailKeeper"
BUNDLE_ID="de.paranoidsecurity.MailKeeper"
IDENTITY="Developer ID Application: Jan Tietjen (Y2LTPLFG6D)"
OUT="build/release/$VERSION_ARG"
DMG="$OUT/$APP_NAME-$VERSION_ARG.dmg"
FEED_BASE="https://github.com/tietjen/mailkeeper/releases/download"

say() { print -P "%F{blue}==>%f $*" }
die() { print -P "%F{red}✗%f $*" >&2; exit 1 }

# ---------------------------------------------------------------- 1. checks

[[ "$(cat VERSION)" == "$VERSION_ARG" ]] || die "VERSION sagt $(cat VERSION), du willst $VERSION_ARG"
grep -q "^## \[$VERSION_ARG\]" CHANGELOG.md || die "CHANGELOG.md hat keinen Abschnitt ## [$VERSION_ARG]"
[[ -z "$(git status --porcelain)" ]] || die "Arbeitsverzeichnis ist nicht sauber"
# In CI the tag is what triggered the run, so it exists in the checkout. Only a tag that
# points somewhere else is a mistake.
if EXISTING=$(git rev-parse -q --verify "v$VERSION_ARG^{commit}" 2>/dev/null); then
  [[ "$EXISTING" == "$(git rev-parse HEAD)" ]] \
    || die "Tag v$VERSION_ARG zeigt auf $EXISTING, HEAD ist $(git rev-parse HEAD)"
fi

# ADR-0013 §5: nothing public before licence AND terms exist. Asked positively — a missing
# file, a renamed one or a reworded sentence must keep the lock shut, not open it.
release_is_allowed() {
  [[ -f LICENSE && -f TERMS.md ]] && grep -q "^SPDX-License-Identifier:" LICENSE
}
if [[ $PUBLISH == 1 ]] && grep -q "^## \[$VERSION_ARG\].*unveröffentlicht" CHANGELOG.md; then
  die "CHANGELOG.md nennt $VERSION_ARG noch „unveröffentlicht“"
fi
if [[ $PUBLISH == 1 ]] && ! release_is_allowed; then
  die "Veröffentlichen gesperrt (ADR-0013): es braucht LICENSE mit einer
      SPDX-License-Identifier-Zeile und TERMS.md. Beides fehlt noch."
fi

say "Tests"
swift test 2>&1 | tail -3

# ---------------------------------------------------------------- 2. build

say "Build $VERSION_ARG"
BUILD_LOG=$(mktemp)
Scripts/build-app.sh >/dev/null 2>"$BUILD_LOG" || { cat "$BUILD_LOG" >&2; rm -f "$BUILD_LOG"; die "Build fehlgeschlagen" }
rm -f "$BUILD_LOG"
APP="build/$APP_NAME.app"
[[ -d "$APP" ]] || die "kein $APP"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$APP" "$OUT/"

# Notarisation first for the app, then the DMG built from the stapled app. The other way
# round leaves the copy inside the DMG without a ticket: a drag install that first runs
# offline is refused by Gatekeeper.
notarize() {
  local what="$1"
  if [[ -n "${APPLE_ID:-}" && -n "$APPLE_PW" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY=(--apple-id "$APPLE_ID" --password "$APPLE_PW" --team-id "$APPLE_TEAM_ID")
  else
    NOTARY=(--keychain-profile "$APP_NAME")
  fi
  local log="$OUT/notarization-${what:t:r}.txt"
  xcrun notarytool submit "$what" "${NOTARY[@]}" --wait | tee "$log"
  grep -q "status: Accepted" "$log" || die "Notarisierung von ${what:t} nicht angenommen"
  xcrun stapler staple "$what"
}

if [[ $NOTARIZE == 1 ]]; then
  say "Notarisierung der App (dauert ein paar Minuten)"
  ZIP="$OUT/$APP_NAME.zip"
  /usr/bin/ditto -c -k --keepParent "$OUT/$APP_NAME.app" "$ZIP"
  notarize "$ZIP"                      # the ticket is issued for the app inside
  xcrun stapler staple "$OUT/$APP_NAME.app"
  rm -f "$ZIP"
else
  say "ohne Notarisierung (--no-notarize) — nicht veröffentlichen"
fi

say "DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
cp -R "$OUT/$APP_NAME.app" "$STAGE/"      # the stapled copy, not the raw build
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION_ARG" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"; trap - EXIT INT TERM
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  say "Notarisierung des DMG"
  notarize "$DMG"
  ASSESS=$(spctl --assess --type execute --verbose=4 "$OUT/$APP_NAME.app" 2>&1 || true)
  [[ "$ASSESS" == *"source=Notarized Developer ID"* ]] \
    || die "Gatekeeper erkennt die App nicht als notarisiert: $ASSESS"
  say "Gatekeeper: accepted, source=Notarized Developer ID"
fi

# ---------------------------------------------------------------- 4. Sparkle signature

say "Sparkle-Signatur"
# A fixed path: there is a second, obsolete sign_update under bin/old_dsa_scripts/, and
# find's order is not defined.
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$SIGN_UPDATE" ]] || die "sign_update fehlt — swift package resolve"
# macOS 26 refuses sign_update access to the keychain entry (-25320), so the key goes through
# a file in a 0700 directory that is removed whatever happens. generate_keys -x refuses to
# overwrite, so the file must not exist yet — hence a directory, not mktemp.
if [[ -n "$SPARKLE_KEY" ]]; then
  # sign_update reads the key from stdin with "-": it never reaches the file system.
  SIGNATURE=$(print -r -- "$SPARKLE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")
else
  # From the keychain it has to go through a file (macOS 26 refuses sign_update the keychain
  # entry, -25320). generate_keys -x will not overwrite, so the file must not exist yet.
  KEYDIR=$(mktemp -d); chmod 700 "$KEYDIR"
  trap 'rm -rf "$KEYDIR"' EXIT INT TERM
  "$SPARKLE_BIN/generate_keys" --account "$APP_NAME" -x "$KEYDIR/ed" >/dev/null 2>&1 \
    || die "kein Sparkle-Schlüssel: weder \$SPARKLE_ED_PRIVATE_KEY noch Schlüsselbund-Konto $APP_NAME"
  chmod 600 "$KEYDIR/ed"
  SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$KEYDIR/ed" "$DMG")
  rm -rf "$KEYDIR"; trap - EXIT INT TERM
fi
[[ "$SIGNATURE" == *edSignature* ]] || die "sign_update lieferte keine Signatur"

# The public key in the bundle must be the one that just signed — otherwise every installed
# copy refuses this update and nobody finds out until the next release.
BUNDLE_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$OUT/$APP_NAME.app/Contents/Info.plist")

# ---------------------------------------------------------------- 5. appcast + sums

say "appcast.xml (Schlüssel der App: $BUNDLE_KEY)"
NOTES=$(awk "/^## \[$VERSION_ARG\]/{f=1;next} /^## \[/{f=0} f" CHANGELOG.md | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MailKeeper</title>
    <link>https://github.com/tietjen/mailkeeper/releases/latest/download/appcast.xml</link>
    <description>Updates für MailKeeper</description>
    <language>de</language>
    <item>
      <title>$VERSION_ARG</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION_ARG</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>$NOTES</pre>]]></description>
      <!-- sign_update already supplies length= next to the signature; writing it again
           would make the XML invalid (duplicate attribute). -->
      <enclosure url="$FEED_BASE/v$VERSION_ARG/$APP_NAME-$VERSION_ARG.dmg"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

# The two checks that decide whether an installed copy will accept this update at all:
# the feed must parse, and the signature must match the public key inside the app bundle —
# not the key that happened to sign, which would only prove itself.
#
# Verified with CryptoKit rather than openssl: /usr/bin/openssl is LibreSSL and has no
# -rawin, so the check would die on a machine without Homebrew's OpenSSL in PATH.
python3 - "$OUT/appcast.xml" <<'CHECK' || die "appcast.xml ist nicht in Ordnung"
import re, sys, xml.dom.minidom
path = sys.argv[1]
xml.dom.minidom.parse(path)                     # also catches a duplicate attribute
text = open(path, encoding="utf-8").read()
found = re.findall(r'sparkle:edSignature="([^"]+)"', text)
if len(found) != 1:
    sys.exit(f"appcast hat {len(found)} Signaturen, erwartet genau eine")
CHECK
APPCAST_SIG=$(python3 -c "
import re,sys
print(re.findall(r'sparkle:edSignature=\"([^\"]+)\"', open(sys.argv[1], encoding='utf-8').read())[0])
" "$OUT/appcast.xml")

VERIFY=$(mktemp -d); trap 'rm -rf "$VERIFY"' EXIT INT TERM
cat > "$VERIFY/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation

// Does the signature in the appcast come from the key whose public half the app carries?
// If not, every installed copy refuses this update — and nobody notices until the next one.
let args = CommandLine.arguments
guard args.count == 4, let publicKeyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let payload = FileManager.default.contents(atPath: args[3]) else {
    FileHandle.standardError.write(Data("verify: unbrauchbare Eingaben\n".utf8))
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard key.isValidSignature(signature, for: payload) else {
        FileHandle.standardError.write(Data("verify: Signatur passt NICHT zum Schlüssel der App\n".utf8))
        exit(1)
    }
    print("    Appcast gültig, Signatur passt zum Schlüssel der App")
} catch {
    FileHandle.standardError.write(Data("verify: \(error)\n".utf8))
    exit(2)
}
SWIFT
swift "$VERIFY/verify.swift" "$BUNDLE_KEY" "$APPCAST_SIG" "$DMG" \
  || die "die Signatur passt nicht zum SUPublicEDKey der App — jede Installation würde dieses Update ablehnen"
rm -rf "$VERIFY"; trap - EXIT INT TERM

(cd "$OUT" && shasum -a 256 *.dmg > SHA256SUMS)
say "fertig: $OUT"
ls -lh "$OUT" | tail -n +2 | awk '{print "    " $9 "  " $5}'

# ---------------------------------------------------------------- 6. publish

if [[ $PUBLISH == 1 ]]; then
  # One publishing path, on purpose: this only sets the tag. The release itself is built and
  # uploaded by .github/workflows/release.yml when the tag reaches the mirror — otherwise two
  # paths would race, `gh release create` would put the tag on the wrong commit, and which DMG
  # ends up in the release would be a matter of mirror latency.
  say "Tag v$VERSION_ARG setzen"
  git tag -a "v$VERSION_ARG" -m "MailKeeper $VERSION_ARG"
  git push origin "v$VERSION_ARG"
  say "getaggt. Das Release baut und veröffentlicht die CI, sobald der Tag am Spiegel ist."
else
  print -P "%F{yellow}nichts veröffentlicht%f — mit --publish (erst wenn Lizenz und Nutzungsbedingungen stehen, ADR-0013)"
fi
