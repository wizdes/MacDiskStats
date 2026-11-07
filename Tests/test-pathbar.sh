#!/bin/zsh
set -euo pipefail
log=build/test-e2e.log
for name in \
  'banner text button and close share vertical center inside window' \
  'status summary estimates and path share vertical center' \
  'banner reserves map space' \
  'estimates label holds full limitation text' \
  'path bar has one item per folder from scan root' \
  'path bar gives way to scan summary' \
  'clicking path folder selects and zooms' \
  'leaving map restores selected path' \
  'narrow window keeps path summary and progress separate' \
  'shared file check error stays visible'; do
  rg -q "^PASS e2e: bug: $name$" "$log"
done
for name in \
  'live path bar follows node ids' \
  'phase one path click selects and zooms' \
  'phase two path bar keeps node ids' \
  'phase two path click selects and zooms' \
  'path control refuses outside root drops' \
  'percent cells fit 100 percent' \
  'unreadable appears only in Size column' \
  'path items have direct node identity' \
  'path items use file and folder icons' \
  'drawn path cells use folder icons' \
  'type percent cells fit 100 percent' \
  'symlink path keeps its node identity' \
  'colliding display names keep distinct ids' \
  'volume root slash has one path item' \
  'unreadable banner clears on new scan' \
  'Cmd-N during scan opens one sheet' \
  'Escape from sheet does not cancel scan' \
  'light status labels follow appearance' \
  'dark status labels follow appearance'; do
  rg -q "^PASS e2e: bug: $name$" "$log"
done
if rg -q '^FAIL e2e:|^SKIP ' "$log"; then exit 1; fi
