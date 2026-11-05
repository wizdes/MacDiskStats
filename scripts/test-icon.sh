#!/bin/zsh
set -euo pipefail
out=build/tmp/icon-regression.iconset
mkdir -p build/tmp
rm -rf -- "$out"
build/make-icon "$out"
for name in icon_16x16.png icon_32x32.png icon_512x512@2x.png; do test -s "$out/$name"; done
sips -g pixelWidth "$out/icon_32x32.png" | rg -q 'pixelWidth: 32'
rm -rf -- "$out"
echo 'PASS icon generation in build/tmp'
