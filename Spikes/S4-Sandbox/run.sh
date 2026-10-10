#!/bin/zsh
# Spike S4 end to end: two ATS variants of the sandbox checks, then a Sparkle update
# v1 → v2 of the sandboxed app from a local, EdDSA-signed feed.
set -euo pipefail
cd "${0:A:h}"
B=build
rm -rf $B && mkdir -p $B/feed $B/keys
swift build -c release --product s4tool >/dev/null
PUBKEY=$(.build/release/s4tool keygen $B/keys/ed25519.key)

python3 -I -m http.server 8765 --bind 127.0.0.1 --directory $B/feed 2> $B/server.log &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

for variant in none local+ziti; do
  print "\n== checks, ATS: $variant"
  ./build-app.sh $B/check-$variant 1 $variant $PUBKEY >/dev/null
  $B/check-$variant/S4Spike.app/Contents/MacOS/S4Spike --auto 2>/dev/null
done

print "\n== Sparkle update v1 → v2 (sandboxed)"
./build-app.sh $B/v2 2 local+ziti $PUBKEY >/dev/null
ditto -c -k --keepParent $B/v2/S4Spike.app $B/feed/S4Spike-2.zip
.build/release/s4tool appcast $B/keys/ed25519.key $B/feed/S4Spike-2.zip \
  http://127.0.0.1:8765/S4Spike-2.zip 2 $B/feed/appcast.xml
./build-app.sh $B/install 1 local+ziti $PUBKEY >/dev/null
open -n $B/install/S4Spike.app --args --update-test
for i in {1..90}; do
  grep -q "launched=v2" $B/server.log 2>/dev/null && break
  grep -qE "update=(error|notFound|start)" $B/server.log 2>/dev/null && break
  sleep 1
done
print "server log (update events):"
grep -oE "GET /report\?[^ ]*" $B/server.log | sed 's/GET \/report?//' | python3 -I -c "import sys,urllib.parse as u; [print('  ', u.unquote_plus(l.strip())) for l in sys.stdin if 'update' in l or 'launched' in l]"
print "installed bundle version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $B/install/S4Spike.app/Contents/Info.plist)"
codesign --verify --strict $B/install/S4Spike.app && print "installed bundle signature: valid"
print "quarantine xattr on installed bundle: $(xattr -p com.apple.quarantine $B/install/S4Spike.app 2>/dev/null || echo none)"
rm -f $B/keys/ed25519.key
