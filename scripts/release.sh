#!/bin/zsh
# Builds a Developer ID–signed, notarized, stapled DMG ready to put on a website.
#   scripts/release.sh            → build/XDRStat-<version>.dmg
#
# One-time setup (stores notarization credentials in your keychain under the profile "XDRStat"):
#   xcrun notarytool store-credentials XDRStat --apple-id <your Apple ID email> --team-id R8BK4688WV
#   (it prompts for an app-specific password from appleid.apple.com → Sign-In and Security)
# Override the profile name with NOTARY_PROFILE=...
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-XDRStat}"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -z "$IDENTITY" ]] && { echo "No 'Developer ID Application' identity in the keychain." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/XDRStat-$VERSION.dmg"

# 1. Build + sign the app (hardened runtime, timestamp, entitlements).
SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh

# 2. Disk image with a drag-to-Applications layout.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/XDRStat.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "XDRStat $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 3. Notarize (Apple scans it; usually a few minutes) and staple the ticket so it opens offline.
echo "Submitting $DMG for notarization…"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
  echo "Notarization failed. See the log with: xcrun notarytool log <submission-id> --keychain-profile $PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$DMG"

# 4. Final Gatekeeper check, as a downloaded file would get.
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Ready: $DMG"
