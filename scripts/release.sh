#!/bin/zsh
# Builds a Developer ID–signed, notarized, stapled DMG ready to put on a website.
#   scripts/release.sh            → build/XDRStat.dmg  (upload it to a GitHub release as "XDRStat.dmg";
#                                   xdrstat.com links to releases/latest/download/XDRStat.dmg)
#
# One-time setup (stores notarization credentials in your keychain under the profile "XDRStat"):
#   xcrun notarytool store-credentials XDRStat --apple-id <your Apple ID email> --team-id R8BK4688WV
#   (it prompts for an app-specific password from appleid.apple.com → Sign-In and Security)
# Override the profile name with NOTARY_PROFILE=...
#
#   scripts/release.sh --publish  → also creates GitHub release v<version> with XDRStat.dmg attached
#                                   (needs `gh auth login` once; bump CFBundleShortVersionString first)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-XDRStat}"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -z "$IDENTITY" ]] && { echo "No 'Developer ID Application' identity in the keychain." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/XDRStat.dmg"
PUBLISH=0; [[ "${1:-}" == "--publish" ]] && PUBLISH=1

# 0. Publishing checks up front, so a mistake fails in seconds rather than after notarization:
#    the release must be built from a clean, pushed commit, and the version tag must be new.
if (( PUBLISH )); then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Uncommitted changes: commit them before publishing." >&2; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "HEAD isn't pushed (or is behind origin): sync before publishing." >&2; exit 1; }
  if gh release view "v$VERSION" --repo karimbacchus/xdrstat >/dev/null 2>&1; then
    echo "Release v$VERSION already exists: bump CFBundleShortVersionString in Resources/Info.plist." >&2; exit 1
  fi
fi
COMMIT=$(git rev-parse HEAD)

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

# 5. Optional: publish as the latest GitHub release (the website's download button points here).
if (( PUBLISH )); then
  # --target pins the tag to the exact commit that was built (not whatever origin's HEAD is by now).
  gh release create "v$VERSION" "$DMG" --repo karimbacchus/xdrstat --target "$COMMIT" \
    --title "XDRStat $VERSION" --notes "Signed with Developer ID and notarized by Apple. Requires macOS 27 or later on Apple Silicon." --latest
  echo "Published: https://github.com/karimbacchus/xdrstat/releases/tag/v$VERSION"
fi
