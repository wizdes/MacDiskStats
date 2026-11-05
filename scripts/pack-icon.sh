#!/bin/zsh
set -euo pipefail
out=${1:-build}
iconutil -c icns "$out/AppIcon.iconset" -o Resources/AppIcon.icns
test -s Resources/AppIcon.icns
mkdir -p "$out/MacDiskStats.app/Contents/Resources"
cp Resources/AppIcon.icns "$out/MacDiskStats.app/Contents/Resources/AppIcon.icns"
echo 'PASS AppIcon.icns packed and installed; rebuild the release app before distribution'
