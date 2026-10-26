#!/usr/bin/env bash
# Regenerates every committed icon asset from scripts/icon/render-icon.swift.
# Usage: scripts/icon/make-icons.sh
# Outputs (commit them, so builds never need to regenerate):
#   App/Resources/AppIcon.icns                          app icon (iconutil)
#   App/Resources/menubar-diamond{,@2x}.png             menu bar template image
#   docs/brand/*.png                                    brand PNGs (icon variants, Icon Composer layers, menu bar mark)
# Needs only Apple tools: swift, iconutil.
set -euo pipefail

cd "$(dirname "$0")/../.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift scripts/icon/render-icon.swift "$work"

mkdir -p App/Resources docs/brand
iconutil -c icns "$work/AppIcon.iconset" -o App/Resources/AppIcon.icns
cp "$work"/brand/*.png docs/brand/
cp "$work/brand/menubar-diamond.png" "$work/brand/menubar-diamond@2x.png" App/Resources/

echo "Wrote App/Resources/AppIcon.icns, App/Resources/menubar-diamond*.png and docs/brand/*.png"
