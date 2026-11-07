#!/bin/zsh
set -euo pipefail
log=build/test-e2e.log
for name in \
  'banner text button and close share vertical center inside window' \
  'estimates label holds full limitation text' \
  'path bar has one item per folder from scan root' \
  'path bar gives way to scan summary' \
  'clicking path folder selects and zooms' \
  'leaving map restores selected path' \
  'narrow window keeps path summary and progress separate' \
  'shared file check error stays visible'; do
  rg -q "^PASS e2e: bug: $name$" "$log"
done
if rg -q '^FAIL e2e:|^SKIP ' "$log"; then exit 1; fi
