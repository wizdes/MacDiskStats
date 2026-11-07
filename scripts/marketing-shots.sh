#!/bin/zsh
set -euo pipefail
scripts/build.sh debug
fixture=build/tmp/marketing-sam
shots=docs/shots
mkdir -p "$shots" build/tmp
rm -rf -- "$fixture"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/sam/Movies/Family videos" "$fixture/sam/Library/Developer/Xcode/DerivedData/PhotoEditor/Build/Products" "$fixture/sam/Projects/garden-site/node_modules" "$fixture/sam/Downloads" "$fixture/sam/Pictures/Photos Library.photoslibrary/originals" "$fixture/sam/Music" "$fixture/sam/Documents/Tax forms"
make_file() { dd if=/dev/zero of="$fixture/sam/$1" bs=1048576 count="$2" status=none; }
make_file 'Movies/Family videos/Beach trip.mov' 64
make_file 'Movies/Family videos/School play.mov' 40
make_file 'Library/Developer/Xcode/DerivedData/PhotoEditor/Build/Products/PhotoEditor.app' 35
make_file 'Projects/garden-site/node_modules/react.bundle' 24
make_file 'Projects/garden-site/node_modules/charts.bundle' 14
make_file 'Downloads/Camera backup.zip' 31
make_file 'Downloads/Installer.dmg' 20
make_file 'Pictures/Photos Library.photoslibrary/originals/IMG_2034.heic' 18
make_file 'Pictures/Photos Library.photoslibrary/originals/IMG_2035.heic' 15
make_file 'Music/Weekend mix.m4a' 13
make_file 'Documents/Tax forms/2025 return.pdf' 4
mkdir -p "$fixture/sam/Projects/garden-site/node_modules/cache"
for i in {1..12000}; do
  printf 'cache entry %s\n' "$i" > "$fixture/sam/Projects/garden-site/node_modules/cache/entry-$i.json"
done
mkdir -p "$fixture/sam/Library/Developer/Xcode/DerivedData/PhotoEditor/Index"
for group in A B C D E F; do
  mkdir "$fixture/sam/Library/Developer/Xcode/DerivedData/PhotoEditor/Index"/unit-$group-{0001..8000}
done
# Use a relative scan path so the screenshot contains no real home-directory name.
for appearance in light dark; do
  MACDISKSTATS_SNAPSHOT_DIR="$(pwd)/$shots" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan "$fixture/sam" --appearance "$appearance" --snapshot "$(pwd)/$shots/finished-$appearance.png"
  MACDISKSTATS_SNAPSHOT_DIR="$(pwd)/$shots" build/MacDiskStats.app/Contents/MacOS/MacDiskStats --snapshot-start "$(pwd)/$shots/start-$appearance.png" --appearance "$appearance"
done
for image in "$shots"/*.png; do test -s "$image"; sips -g pixelWidth -g pixelHeight "$image" | tail -2; done
