#!/bin/zsh
set -euo pipefail
source_file=${1:-Sources/DiskCore/Scanner.swift}
if [[ ! -r "$source_file" || ! -f "$source_file" ]]; then
  print "FAIL scanner source unreadable: $source_file" >&2
  exit 1
fi
search_status=0
rg -q 's\.counted\[[^]]+\][[:space:]]*\+=' "$source_file" || search_status=$?
if (( search_status == 0 )); then
  print 'FAIL bug: finalization and cancellation race with live snapshots'
  exit 1
fi
if (( search_status != 1 )); then exit "$search_status"; fi
search_status=0
rg -q 'else if state\.(cancelled|storageLimit|failed)' "$source_file" || search_status=$?
if (( search_status == 0 )); then
  print 'FAIL bug: finalization and cancellation race with live snapshots'
  exit 1
fi
if (( search_status != 1 )); then exit "$search_status"; fi
print 'PASS bug: finalization and cancellation race with live snapshots'
