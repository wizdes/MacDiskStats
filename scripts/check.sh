#!/bin/zsh
set -euo pipefail
out=${CUSHION_BUILD_OUT:-build}
start=$SECONDS
scripts/build.sh debug --out "$out"
"$out/checks" | tee "$out/check-output.txt"
scripts/check-readonly.sh
tests=$(sed -n 's/^checks \([0-9][0-9]*\), failed 0$/\1/p' "$out/check-output.txt")
if [[ -z "$tests" ]]; then echo 'check count missing' >&2; exit 1; fi
printf '%s,%s,change,%s,%s\n' "$(date -u +%Y-%m-%d)" "$(git rev-parse --short HEAD)" "$tests" "$((SECONDS-start))" >> docs/test-times.csv
echo "check: $tests tests, $((SECONDS-start)) seconds"
