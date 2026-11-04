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
