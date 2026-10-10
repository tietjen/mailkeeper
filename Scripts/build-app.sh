#!/bin/zsh
# Build MailKeeper.app: release build, bundle, Developer ID signature with hardened runtime
# and App Sandbox (ADR-0003). Sparkle is added in Phase 8.
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
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MailKeeperGUI "$APP/Contents/MacOS/MailKeeper"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>MailKeeper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Jan Tietjen — MIT License</string>
  <key>NSHighResolutionCapable</key><true/>
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
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict>
</plist>
ENTITLEMENTS

if [[ $SIGN == 1 ]]; then
  TS=--timestamp
  [[ $DEV == 1 ]] && TS=--timestamp=none
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$APP"
else
  codesign --force --options runtime --entitlements "$ENT" --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "==> $APP ($VERSION, build $BUILD)"
