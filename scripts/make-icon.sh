#!/bin/zsh
# Rebuilds the app icon from Resources/AppIcon.icon (an Icon Composer document: Liquid Glass).
# Needs Xcode for actool; the outputs (Assets.car, AppIcon.icns) are committed so normal builds don't.
#   scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift scripts/make-icon-layer.swift Resources/AppIcon/icon-1024.png Resources/AppIcon.icon/Assets/gauge.png
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
xcrun actool Resources/AppIcon.icon --compile "$OUT" --output-format human-readable-text --warnings --errors \
  --output-partial-info-plist "$OUT/partial.plist" --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en --target-device mac \
  --minimum-deployment-target 27.0 --platform macosx >/dev/null
cp "$OUT/Assets.car" "$OUT/AppIcon.icns" Resources/
echo "Updated Resources/Assets.car and Resources/AppIcon.icns"
