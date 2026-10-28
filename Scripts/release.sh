#!/bin/zsh
# One release of MailKeeper: checks, build, DMG, notarisation, Sparkle signature, appcast.
#
#   Scripts/release.sh 0.2.0              build and sign everything, publish nothing
#   Scripts/release.sh 0.2.0 --no-notarize   dry run without Apple (for trying things out)
#   Scripts/release.sh 0.2.0 --publish    additionally tag and upload  ← see ADR-0013
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
git rev-parse "v$VERSION_ARG" >/dev/null 2>&1 && die "Tag v$VERSION_ARG gibt es schon"

# ADR-0013: the source is readable, the licence is not settled. Until it is, no public
# binaries — a build that anyone may download needs terms that say what they may do with it.
if [[ $PUBLISH == 1 ]] && grep -q "A licence will follow" LICENSE; then
  die "Veröffentlichen gesperrt: die Lizenz steht noch nicht (ADR-0013).
      Erst LICENSE und Nutzungsbedingungen festlegen, dann --publish."
fi

say "Tests"
swift test 2>&1 | tail -3

# ---------------------------------------------------------------- 2. build

say "Build $VERSION_ARG"
Scripts/build-app.sh >/dev/null 2>"$TMPDIR/mk-build.log" || { cat "$TMPDIR/mk-build.log" >&2; die "Build fehlgeschlagen" }
APP="build/$APP_NAME.app"
[[ -d "$APP" ]] || die "kein $APP"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$APP" "$OUT/"

say "DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION_ARG" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---------------------------------------------------------------- 3. notarisation

if [[ $NOTARIZE == 1 ]]; then
  say "Notarisierung (dauert ein paar Minuten)"
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    NOTARY=(--keychain-profile "$APP_NAME")
  fi
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait | tee "$OUT/notarization.txt"
  grep -q "status: Accepted" "$OUT/notarization.txt" || die "Notarisierung nicht angenommen"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$OUT/$APP_NAME.app"
  spctl --assess --type execute --verbose=4 "$OUT/$APP_NAME.app" 2>&1 | grep -q "source=Notarized Developer ID" \
    || die "Gatekeeper erkennt die App nicht als notarisiert"
  say "Gatekeeper: accepted, source=Notarized Developer ID"
else
  say "ohne Notarisierung (--no-notarize) — nicht veröffentlichen"
fi

# ---------------------------------------------------------------- 4. Sparkle signature

say "Sparkle-Signatur"
SIGN_UPDATE=$(find .build/artifacts/sparkle -name sign_update -type f | head -1)
[[ -n "$SIGN_UPDATE" ]] || die "sign_update fehlt — swift package resolve"
# macOS 26 refuses sign_update access to the keychain entry (-25320), so the key goes through
# a file in a 0700 directory that is removed whatever happens. generate_keys -x refuses to
# overwrite, so the file must not exist yet — hence a directory, not mktemp.
KEYDIR=$(mktemp -d); chmod 700 "$KEYDIR"
KEYFILE="$KEYDIR/ed"
trap 'rm -rf "$KEYDIR"' EXIT INT TERM
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  (umask 077; print -rn -- "$SPARKLE_ED_PRIVATE_KEY" > "$KEYFILE")
else
  GENERATE_KEYS=$(find .build/artifacts/sparkle -name generate_keys -type f | head -1)
  "$GENERATE_KEYS" --account "$APP_NAME" -x "$KEYFILE" >/dev/null 2>&1 \
    || die "kein Sparkle-Schlüssel: weder \$SPARKLE_ED_PRIVATE_KEY noch Schlüsselbund-Konto $APP_NAME"
  chmod 600 "$KEYFILE"
fi
SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$DMG")
rm -rf "$KEYDIR"; trap - EXIT INT TERM
[[ "$SIGNATURE" == *edSignature* ]] || die "sign_update lieferte keine Signatur"

# The public key in the bundle must be the one that just signed — otherwise every installed
# copy refuses this update and nobody finds out until the next release.
BUNDLE_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$OUT/$APP_NAME.app/Contents/Info.plist")
say "signiert mit dem Schlüssel zu $BUNDLE_KEY"

# ---------------------------------------------------------------- 5. appcast + sums

say "appcast.xml"
NOTES=$(awk "/^## \[$VERSION_ARG\]/{f=1;next} /^## \[/{f=0} f" CHANGELOG.md | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MailKeeper</title>
    <link>$FEED_BASE/latest/download/appcast.xml</link>
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
python3 - "$OUT/appcast.xml" "$DMG" "$BUNDLE_KEY" <<'CHECK' || die "Appcast-Prüfung fehlgeschlagen"
import base64, os, re, subprocess, sys, tempfile, xml.dom.minidom
appcast, dmg, pub_b64 = sys.argv[1], sys.argv[2], sys.argv[3]
xml.dom.minidom.parse(appcast)                     # raises on a duplicate attribute, too
text = open(appcast).read()
found = re.findall(r'sparkle:edSignature="([^"]+)"', text)
if len(found) != 1:
    sys.exit(f"appcast hat {len(found)} Signaturen, erwartet genau eine")
der = bytes.fromhex("302a300506032b6570032100") + base64.b64decode(pub_b64)
with tempfile.TemporaryDirectory() as d:
    key = os.path.join(d, "pub.der"); open(key, "wb").write(der)
    sig = os.path.join(d, "sig.bin"); open(sig, "wb").write(base64.b64decode(found[0]))
    r = subprocess.run(["openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", key,
                        "-keyform", "DER", "-sigfile", sig, "-in", dmg], capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("die Signatur passt NICHT zum SUPublicEDKey der App — jede Installation "
             "würde dieses Update ablehnen: " + (r.stdout + r.stderr).strip())
print("    Appcast gültig, Signatur passt zum Schlüssel der App")
CHECK

(cd "$OUT" && shasum -a 256 *.dmg > SHA256SUMS)
say "fertig: $OUT"
ls -lh "$OUT" | tail -n +2 | awk '{print "    " $9 "  " $5}'

# ---------------------------------------------------------------- 6. publish

if [[ $PUBLISH == 1 ]]; then
  say "Tag v$VERSION_ARG"
  git tag -a "v$VERSION_ARG" -m "MailKeeper $VERSION_ARG"
  git push origin "v$VERSION_ARG"
  command -v gh >/dev/null || die "gh fehlt — Release von Hand anlegen"
  gh release create "v$VERSION_ARG" --repo tietjen/mailkeeper --title "MailKeeper $VERSION_ARG" \
     --notes "$NOTES" "$DMG" "$OUT/appcast.xml" "$OUT/SHA256SUMS"
  say "veröffentlicht"
else
  print -P "%F{yellow}nichts veröffentlicht%f — mit --publish (erst wenn die Lizenz steht, ADR-0013)"
fi
