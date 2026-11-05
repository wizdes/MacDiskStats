#!/bin/zsh
set -euo pipefail
source_file=${1:-Sources/DiskCore/Scanner.swift}
if rg -q 's\.counted\[[^]]+\][[:space:]]*\+=' "$source_file" || rg -q 'else if state\.(cancelled|storageLimit|failed)' "$source_file"; then
  print 'FAIL bug: finalization and cancellation race with live snapshots'
  exit 1
fi
print 'PASS bug: finalization and cancellation race with live snapshots'
