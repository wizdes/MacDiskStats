#!/bin/zsh
set -euo pipefail
scripts/build.sh release
for private in yes no; do
  for run in 1 2; do
    echo "scan / private=$private run=$run"
    if [[ $private == yes ]]; then build/cushion-bench / --json; else build/cushion-bench / --no-private --json; fi
  done
done
df -k / /System/Volumes/Data
