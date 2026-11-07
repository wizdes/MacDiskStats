#!/bin/zsh
set -euo pipefail
scripts/build.sh debug
mkdir -p build/snapshots
snapshot_dir="$(cd build/snapshots && pwd)"
for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan /Applications --appearance "$appearance" --snapshot "$snapshot_dir/applications-$appearance.png"
  test -s "$snapshot_dir/applications-$appearance.png"
  echo "snapshot $appearance: $snapshot_dir/applications-$appearance.png"
done

fixture=$(mktemp -d "$(pwd)/build/tmp/mds-banner.XXXXXX")
trap 'chmod 700 "$fixture/unreadable" 2>/dev/null || true; rm -r "$fixture"' EXIT
mkdir -p "$fixture/folder/inside/deep" "$fixture/unreadable"
dd if=/dev/zero of="$fixture/folder/inside/deep/selected-file.dat" bs=4096 count=32 2>/dev/null
chmod 000 "$fixture/unreadable"
for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan "$fixture" --select "$fixture/folder/inside/deep/selected-file.dat" --appearance "$appearance" --snapshot "$snapshot_dir/banner-path-$appearance.png"
  test -s "$snapshot_dir/banner-path-$appearance.png"
  echo "banner path snapshot $appearance: $snapshot_dir/banner-path-$appearance.png"
done
for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan "$fixture" --select "$fixture/folder/inside/deep/selected-file.dat" --appearance "$appearance" --snapshot-min-width --snapshot "$snapshot_dir/min-width-$appearance.png"
  test -s "$snapshot_dir/min-width-$appearance.png"
  test "$(sips -g pixelWidth "$snapshot_dir/min-width-$appearance.png" | tail -n 1 | awk '{print $2}')" -le 1800
  echo "minimum width snapshot $appearance: $snapshot_dir/min-width-$appearance.png"
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan "$fixture" --appearance "$appearance" --snapshot-top100 "$snapshot_dir/top100-$appearance.png"
  test -s "$snapshot_dir/top100-$appearance.png"
  echo "Top 100 snapshot $appearance: $snapshot_dir/top100-$appearance.png"
done
for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan /Applications --appearance "$appearance" --snapshot-at-seconds 1 --snapshot "$snapshot_dir/live-$appearance.png"
  test -s "$snapshot_dir/live-$appearance.png"
  echo "live snapshot $appearance: $snapshot_dir/live-$appearance.png"
done

for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --snapshot-start "$snapshot_dir/start-$appearance.png" --appearance "$appearance"
  test -s "$snapshot_dir/start-$appearance.png"
  echo "start snapshot $appearance: $snapshot_dir/start-$appearance.png"
  MACDISKSTATS_SNAPSHOT_DIR="$snapshot_dir" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --snapshot-mid-scan "$snapshot_dir/mid-scan-$appearance.png" --appearance "$appearance"
  test -s "$snapshot_dir/mid-scan-$appearance.png"
  echo "mid-scan snapshot $appearance: $snapshot_dir/mid-scan-$appearance.png"
done
