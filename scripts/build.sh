#!/bin/zsh
set -euo pipefail
mode=${1:-debug}
if [[ "$mode" != debug && "$mode" != release ]]; then echo 'usage: build.sh [debug|release] [--out DIR]' >&2; exit 2; fi
shift || true
out=build
if [[ ${1:-} == --out ]]; then out=${2:?missing output directory}; fi
mkdir -p "$out/tmp" "$out/module-cache"
export TMPDIR="$(cd "$out/tmp" && pwd)/"
export CLANG_MODULE_CACHE_PATH="$(cd "$out/module-cache" && pwd)"
start=$SECONDS
opt=()
if [[ "$mode" == release ]]; then opt=(-O -wmo); else opt=(-Onone -g -wmo); fi
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -parse-as-library -emit-module -emit-object -module-name DiskCore Sources/DiskCore/*.swift -emit-module-path "$out/DiskCore.swiftmodule" -o "$out/DiskCore.o"
libtool -static -o "$out/libDiskCore.a" "$out/DiskCore.o"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Sources/cushion-bench/*.swift "$out/libDiskCore.a" -o "$out/cushion-bench"
swiftc -swift-version 6 -target arm64-apple-macos15.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${opt[@]}" -I "$out" Tests/checks/*.swift "$out/libDiskCore.a" -o "$out/checks"
echo "build $mode: $((SECONDS-start)) seconds"
