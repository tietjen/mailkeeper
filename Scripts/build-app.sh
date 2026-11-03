#!/bin/zsh
# Build MailKeeper.app: release build, bundle, Sparkle, Developer ID signature with hardened
# runtime and App Sandbox (ADR-0003, ADR-0013).
# usage: Scripts/build-app.sh [--no-sign | --dev]   → build/MailKeeper.app
#   --dev: "MailKeeper Dev" (bundle id …MailKeeper.dev), Developer ID, NO sandbox — honours
#          MAILKEEPER_ARCHIVE (open --env MAILKEEPER_ARCHIVE=/path build/MailKeeper\ Dev.app)
set -euo pipefail
cd "${0:A:h}/.."
SIGN=1 DEV=0
[[ "${1:-}" == "--no-sign" ]] && SIGN=0
[[ "${1:-}" == "--dev" ]] && { DEV=1; }  # still Developer ID signed: stable keychain identity
IDENTITY="Developer ID Application: Jan Tietjen (Y2LTPLFG6D)"
BUNDLE_ID="de.paranoidsecurity.MailKeeper"
APP_NAME="MailKeeper"
if [[ $DEV == 1 ]]; then BUNDLE_ID="$BUNDLE_ID.dev"; APP_NAME="MailKeeper Dev"; fi
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release --product MailKeeperGUI
swift build -c release --product MailKeeperPDFService
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MailKeeperGUI "$APP/Contents/MacOS/MailKeeper"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# The string catalogue goes into the MAIN bundle: SwiftUI and String(localized:) look there,
# not in a SwiftPM resource bundle. One catalogue serves the GUI and the error texts out of
# Kit, IMAP and AI (LaunchKeeper lesson).
CATALOG="Localization/Localizable.xcstrings"
if [[ -f "$CATALOG" ]]; then
  xcrun xcstringstool compile "$CATALOG" --output-directory "$APP/Contents/Resources"
  # German is the source language: its texts are the keys themselves, so it gets no .lproj —
  # but it must still be listed, or macOS would offer a German system only English.
  SOURCE_LANG=$(python3 -c "import json;print(json.load(open('$CATALOG'))['sourceLanguage'])")
  COMPILED=("${(@f)$(cd "$APP/Contents/Resources" && print -l *.lproj(N:r))}")
  LANGS="$SOURCE_LANG"
  for l in $COMPILED; do [[ -n "$l" && "$l" != "$SOURCE_LANG" ]] && LANGS="$LANGS,$l"; done
  # A compile that writes nothing exits 0, and the app would ship German-only with a valid
  # signature and a green CI — the same trap as the missing rpath below.
  WANT=$(python3 -c "
import json
cat = json.load(open('$CATALOG'))
langs = {l for e in cat['strings'].values() for l in e.get('localizations', {})} - {cat['sourceLanguage']}
print(','.join(sorted(langs)))")
  for l in ${(s:,:)WANT}; do
    [[ -s "$APP/Contents/Resources/$l.lproj/Localizable.strings" ]] \
      || { echo "xcstringstool hat $l.lproj nicht geschrieben — die App wäre einsprachig" >&2; exit 1 }
  done
else
  LANGS="de"
fi

# ADR-0009: PDF text service — sandboxed, no network, no files; sandboxed in --dev too.
SVC_ID="de.paranoidsecurity.MailKeeper.PDFText"
XPC="$APP/Contents/XPCServices/$SVC_ID.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp .build/release/MailKeeperPDFService "$XPC/Contents/MacOS/MailKeeperPDFService"
cat > "$XPC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$SVC_ID</string>
  <key>CFBundleName</key><string>MailKeeper PDF Text</string>
  <key>CFBundleExecutable</key><string>MailKeeperPDFService</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>XPCService</key>
  <dict>
    <key>ServiceType</key><string>Application</string>
  </dict>
</dict>
</plist>
PLIST
SVC_ENT="build/MailKeeperPDFText.entitlements"
cat > "$SVC_ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
ENTITLEMENTS

# Sparkle (ADR-0013): the framework is copied in, and the executable gets the rpath SwiftPM
# does not set. Spike S4 verified the whole update run in the sandbox.
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FW" ]] || { echo "Sparkle fehlt — swift package resolve" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MailKeeper" 2>/dev/null || true
# Without the rpath the app dies at launch in dyld, and codesign --verify would not notice.
otool -l "$APP/Contents/MacOS/MailKeeper" | grep -q "@executable_path/../Frameworks" \
  || { echo "rpath auf ../Frameworks fehlt — die App würde beim Start abstürzen" >&2; exit 1 }

# Licences (ADR-0013): our own terms, and those of every component compiled in or bundled.
# Apache 2.0 (SwiftNIO & co.), MIT (Sparkle) and the OpenSSL licence (BoringSSL inside
# swift-nio-ssl) each want their text in every copy that is passed on — the DMG is one.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp TERMS.md "$APP/Contents/Resources/TERMS.md"
# Two components carry code under other licences than their own and name it only by URL:
# swift-nio-ssl vendors BoringSSL without its LICENSE (packaging/licenses/BoringSSL.txt is the
# upstream file of exactly this commit), and the NOTICE.txt of swift-nio and swift-nio-imap
# point to MIT/BSD texts (packaging/licenses/SwiftNIO-embedded.txt, collected for exactly these
# NOTICE files). A new version may bring other terms: then collect them again.
BORINGSSL_COMMIT="817ab07ebb53da35afea409ab9328f578492832d"
NOTICE_SHA256=(
  swift-nio d25ed2452b3476c342082d11e4e8bf5459174d2836124f842b499850bcebc50e
  swift-nio-imap 6f29dd1a27852835fdd71498cae17ce808ea5cf607e14d022943c718ad6db8d4
)
[[ -f .build/checkouts/swift-nio-ssl/Package.swift ]] \
  || { echo "swift-nio-ssl fehlt in .build/checkouts — swift package resolve" >&2; exit 1 }
grep -q "BoringSSL Commit: $BORINGSSL_COMMIT" .build/checkouts/swift-nio-ssl/Package.swift \
  || { echo "swift-nio-ssl bringt ein anderes BoringSSL mit — packaging/licenses/BoringSSL.txt erneuern" >&2; exit 1 }
for dir sum in $NOTICE_SHA256; do
  [[ "$(shasum -a 256 < .build/checkouts/$dir/NOTICE.txt 2>/dev/null)" == "$sum  -" ]] \
    || { echo "$dir/NOTICE.txt hat sich geändert — packaging/licenses/SwiftNIO-embedded.txt prüfen" >&2; exit 1 }
done
# Captured first: a failing generator inside `< <(…)` would go unnoticed by set -e and leave a
# notices file with nothing but its header line.
PINS=$(python3 -c "
import json, os
for p in json.load(open('Package.resolved'))['pins']:
    s = p['state']
    print(os.path.basename(p['location']).removesuffix('.git'), p['location'], s.get('version') or s['revision'], sep='\t')") \
  || { echo "Package.resolved nicht lesbar — keine Fremdlizenzen" >&2; exit 1 }
[[ -n "$PINS" ]] || { echo "Package.resolved ohne Pakete — keine Fremdlizenzen" >&2; exit 1 }
NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
{
  print "MailKeeper contains the following third-party software.\n"
  while IFS=$'\t' read -r dir url ver; do
    d=".build/checkouts/$dir"
    [[ -d "$d" ]] || { echo "$d fehlt — swift package resolve" >&2; exit 1 }
    lic=($d/(LICENSE|LICENSE.txt|LICENSE.md)(N))
    (( $#lic )) || { echo "keine Lizenzdatei in $d — die App ginge ohne sie hinaus" >&2; exit 1 }
    print "==== $dir $ver ($url)\n"
    cat "$lic[1]"
    [[ -f "$d/NOTICE.txt" ]] && { print "\n---- NOTICE\n"; cat "$d/NOTICE.txt" }
    [[ $dir == swift-nio-ssl ]] && { print "\n---- BoringSSL $BORINGSSL_COMMIT\n"; cat packaging/licenses/BoringSSL.txt }
    [[ $dir == swift-nio ]] && { print; cat packaging/licenses/SwiftNIO-embedded.txt }
    print
  done <<< "$PINS"
} > "$NOTICES"
[[ $(grep -c '^==== ' "$NOTICES") == ${#${(f)PINS}} ]] \
  || { echo "ThirdPartyNotices.txt ist unvollständig" >&2; exit 1 }

# The public key of the update signature. Its private half lives in the login keychain
# (account "MailKeeper") and in the vault; see ADR-0013. Changing it makes every installed
# copy refuse every future update.
SU_PUBLIC_KEY="H1LoPh3aWMFX2d7rT+RHlB5H5ZSSeShjTnvw6kuyge0="
SU_FEED="https://github.com/tietjen/mailkeeper/releases/latest/download/appcast.xml"
# A dev build must never pull a release over itself: no feed, no automatic checks.
if [[ $DEV == 1 ]]; then
  SPARKLE_KEYS="  <key>SUEnableAutomaticChecks</key><false/>"
else
  # SUEnableAutomaticChecks is deliberately NOT set: setting it — to true or false — makes
  # Sparkle skip its own permission dialogue and start checking github.com unasked. For an
  # app whose promise is that nothing leaves the Mac, that question belongs to the user.
  # Without the key, Sparkle asks on the second start and remembers the answer.
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>$SU_FEED</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <!-- sandboxed updates go through Sparkle's installer launcher service (spike S4) -->
  <key>SUEnableInstallerLauncherService</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>MailKeeper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array>$(print -l ${(s:,:)LANGS} | sed 's|.*|<string>&</string>|')</array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Jan Tietjen · PolyForm Noncommercial 1.0.0</string>
  <key>NSHighResolutionCapable</key><true/>
$SPARKLE_KEYS
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>ziti</key>
      <dict>
        <key>NSIncludesSubdomains</key><true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

ENT="build/$APP_NAME.entitlements"
cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><$([[ $DEV == 1 ]] && echo false || echo true)/>
  <key>com.apple.security.network.client</key><true/>
  <!-- 7.1: the loopback redirect of the Google sign-in (RFC 8252) listens on 127.0.0.1
       for the seconds the browser needs to come back. -->
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
$([[ $DEV == 1 ]] || echo "  <!-- Sparkle's installer services in the sandbox (spike S4) -->
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array><string>$BUNDLE_ID-spks</string><string>$BUNDLE_ID-spki</string></array>")
</dict>
</plist>
ENTITLEMENTS

# Inner code first, then outwards — never --deep: it would leave Sparkle's binaries signed by
# the Sparkle team, and library validation would then refuse them.
if [[ $SIGN == 1 ]]; then
  TS=--timestamp
  [[ $DEV == 1 ]] && TS=--timestamp=none
  SIGN_AS=("$IDENTITY")
else
  TS=""
  SIGN_AS=(-)
fi
sign() { codesign --force --options runtime ${TS:+$TS} "${@:2}" --sign "${SIGN_AS[@]}" "$1" }

SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# --preserve-metadata=entitlements is what Sparkle's docs ask for. In 2.10.1 the service
# ships without entitlements, so it changes nothing today — it is here for the day it does.
sign "$SP/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$SP/XPCServices/Installer.xpc"
sign "$SP/Updater.app"
sign "$SP/Autoupdate"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$XPC" --entitlements "$SVC_ENT"
sign "$APP" --entitlements "$ENT"

codesign --verify --strict --verbose=1 "$XPC"
codesign --verify --strict --verbose=1 "$APP"
echo "==> $APP ($VERSION, build $BUILD)"
