#!/bin/zsh
# Build mkctl (release) and sign it with the Developer ID. A stable signature keeps the
# keychain's "always allow" valid across rebuilds; ad-hoc builds look like a new program to
# the keychain after every build and trigger an access prompt each time.
# usage: Scripts/build-cli.sh   → .build/release/mkctl
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="Developer ID Application: Jan Tietjen (Y2LTPLFG6D)"
swift build -c release --product mkctl
codesign --force --options runtime --timestamp=none --identifier de.paranoidsecurity.mkctl --sign "$IDENTITY" .build/release/mkctl
codesign --verify --strict .build/release/mkctl
echo "==> .build/release/mkctl (signed)"
