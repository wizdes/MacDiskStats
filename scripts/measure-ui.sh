#!/bin/zsh
set -euo pipefail
if [[ $# != 1 ]]; then echo 'usage: measure-ui.sh <path>' >&2; exit 2; fi
scripts/build.sh measure
build/MacDiskStats.app/Contents/MacOS/MacDiskStats --scan "$1" --measure
