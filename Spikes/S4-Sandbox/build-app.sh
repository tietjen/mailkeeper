#!/bin/zsh
# Assemble, sign (Developer ID, hardened runtime, App Sandbox) the S4 probe app.
# usage: build-app.sh <outdir> <version> <ats: none|local+ziti> <SUPublicEDKey>
set -euo pipefail
cd "${0:A:h}"
OUT=$1 VERSION=$2 ATS=$3 PUBKEY=$4
IDENTITY="Developer ID Application: Jan Tietjen (Y2LTPLFG6D)"
BUNDLE_ID="de.paranoidsecurity.MailKeeper.S4Spike"
FEED="http://127.0.0.1:8765/appcast.xml"

swift build -c release --product S4Spike >/dev/null
APP="$OUT/S4Spike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/S4Spike "$APP/Contents/MacOS/S4Spike"
cp -R .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/S4Spike"

ATS_XML=""
if [[ $ATS == local+ziti ]]; then
  # Local networking (localhost, .local, bare names) plus plain HTTP for *.ziti only
  # (OpenZiti encrypts the transport; LiteLLM is served as http://litellm.rk1.ziti:4000).
  ATS_XML='<key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key><dict>
      <key>ziti</key><dict>
        <key>NSIncludesSubdomains</key><true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
  </dict>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>S4Spike</string>
  <key>CFBundleExecutable</key><string>S4Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>0.0.$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$PUBKEY</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUEnableInstallerLauncherService</key><true/>
  $ATS_XML
</dict>
</plist>
PLIST

ENT="$OUT/entitlements.plist"
cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
    <string>$BUNDLE_ID-spks</string>
    <string>$BUNDLE_ID-spki</string>
  </array>
</dict>
</plist>
ENTITLEMENTS

SIGN=(--force --options runtime --timestamp=none --sign "$IDENTITY")
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
codesign "${SIGN[@]}" "$S/XPCServices/Installer.xpc"
codesign "${SIGN[@]}" "$S/Updater.app"
codesign "${SIGN[@]}" "$S/Autoupdate"
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN[@]}" --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (version $VERSION, ATS $ATS)"
