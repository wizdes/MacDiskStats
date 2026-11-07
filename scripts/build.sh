#!/bin/zsh
set -euo pipefail
mode=${1:-debug}
if [[ "$mode" != debug && "$mode" != release && "$mode" != measure ]]; then echo 'usage: build.sh [debug|release|measure] [--out DIR]' >&2; exit 2; fi
shift || true
out=build
if [[ ${1:-} == --out ]]; then out=${2:?missing output directory}; fi
mkdir -p "$out/tmp" "$out/module-cache"
export TMPDIR="$(cd "$out/tmp" && pwd)/"
export CLANG_MODULE_CACHE_PATH="$(cd "$out/module-cache" && pwd)"
start=$SECONDS
opt=()
if [[ "$mode" == release ]]; then opt=(-O -wmo); elif [[ "$mode" == measure ]]; then opt=(-O -g -D DEBUG); else opt=(-Onone -g -wmo -D DEBUG); fi
coreOpt=("${opt[@]}")
if [[ "$mode" == measure ]]; then coreOpt+=(-wmo); fi
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${coreOpt[@]}" -parse-as-library -emit-module -emit-object -module-name DiskCore Sources/DiskCore/*.swift -emit-module-path "$out/DiskCore.swiftmodule" -o "$out/DiskCore.o"
libtool -static -o "$out/libDiskCore.a" "$out/DiskCore.o"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Sources/macdiskstats-bench/*.swift "$out/libDiskCore.a" -o "$out/macdiskstats-bench"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Tools/macdiskstats-map/*.swift "$out/libDiskCore.a" -o "$out/macdiskstats-map"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Tools/scan-lab/*.swift "$out/libDiskCore.a" -o "$out/scan-lab"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Tests/checks/*.swift "$out/libDiskCore.a" -o "$out/checks"
app="$out/MacDiskStats.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.yili.MacDiskStats</string>
<key>CFBundleName</key><string>MacDiskStats</string>
<key>CFBundleDisplayName</key><string>MacDiskStats</string>
<key>CFBundleExecutable</key><string>MacDiskStats</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yi Li</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Sources/MacDiskStatsApp/*.swift "$out/libDiskCore.a" -framework AppKit -framework QuickLookUI -o "$app/Contents/MacOS/MacDiskStats"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Tools/make-icon/*.swift "$out/libDiskCore.a" -framework AppKit -o "$out/make-icon"
"$out/make-icon" "$out/AppIcon.iconset"
if ! iconutil -c icns "$out/AppIcon.iconset" -o Resources/AppIcon.icns; then
  echo 'iconutil could not pack AppIcon.icns here; run scripts/pack-icon.sh outside this sandbox' >&2
fi
if [[ -s Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
if [[ "$mode" == release ]]; then
  sign_id="${MDS_SIGN_ID:-${CUSHION_SIGN_ID:-}}"
  if [[ -n "$sign_id" ]]; then
    codesign --force --options runtime --timestamp --sign "$sign_id" --entitlements Resources/MacDiskStats.entitlements "$app"
  else
    codesign --force --sign - --entitlements Resources/MacDiskStats.entitlements "$app"
  fi
else
  codesign --force --sign - "$app"
fi
echo "build $mode: $((SECONDS-start)) seconds"
