#!/bin/zsh
# Builds XDRStat.app into ./build. Usage: scripts/build-app.sh [--run]
#
# Signing: uses the first "Developer ID Application" identity in your keychain (hardened runtime +
# secure timestamp, ready for notarization). Override with SIGN_IDENTITY="..." or force an ad-hoc
# local build with SIGN_IDENTITY=-
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --scratch-path .build-release
APP=build/XDRStat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build-release/release/XDRStat "$APP/Contents/MacOS/XDRStat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="-"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (local use only)"
else
  codesign --force --options runtime --timestamp \
    --entitlements Resources/XDRStat.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"
  echo "Signed with: $SIGN_IDENTITY"
fi
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x XDRStat 2>/dev/null || true
  open "$APP"
fi
