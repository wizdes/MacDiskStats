#!/bin/zsh
set -euo pipefail
scripts/build.sh release
export TMPDIR="$(pwd)/build/tmp/"
export CLANG_MODULE_CACHE_PATH="$(pwd)/build/module-cache"
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/MacDiskStatsProbe.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -O -I build scripts/sandbox-probe.swift build/libDiskCore.a -o "$app/Contents/MacOS/MacDiskStatsProbe"
cat > "$probe_dir/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>/</string></array>
</dict></plist>
PLIST
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.macdiskstats.probe</string><key>CFBundleExecutable</key><string>MacDiskStatsProbe</string></dict></plist>
PLIST
codesign --force --sign - --entitlements "$probe_dir/entitlements.plist" "$app"
"$app/Contents/MacOS/MacDiskStatsProbe"
build/macdiskstats-bench "$HOME" --json
