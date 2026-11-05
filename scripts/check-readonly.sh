#!/bin/zsh
set -euo pipefail
pattern='\b(unlink|unlinkat|rmdir|rename|renameat|removeItem|moveItem|trashItem|recycle|ftruncate|clonefile|copyfile|copyItem|createFile|createDirectory|mkdir|mkdirat|link|linkat|symlink|symlinkat|setxattr|fsetxattr|removexattr|setattrlist|fsetattrlist|utimes|futimes|chmod|fchmod|chown|fchown|truncate|pwrite|writev|fwrite|fputs|fprintf)\s*\(|\bwrite\s*\(|FileHandle\s*\(\s*forWriting|\.write\s*\(\s*to\s*:|\bO_WRONLY\b|\bO_RDWR\b|\bO_CREAT\b|\bO_TRUNC\b'
if ! command -v rg >/dev/null 2>&1; then echo 'FAIL: rg unavailable' >&2; exit 1; fi
if rg -n --glob '*.swift' --glob '!DebugSnapshot.swift' "$pattern" Sources; then
  echo 'FAIL: Sources contains a file-changing call' >&2
  exit 1
else
  result=$?
  if [[ $result != 1 ]]; then echo 'FAIL: source search failed' >&2; exit 1; fi
fi
if rg -n --glob '*.swift' 'DebugSnapshot|#if DEBUG' Sources/MacDiskStatsApp | rg -v 'Sources/MacDiskStatsApp/(Main|DebugSnapshot)\.swift'; then
  echo 'FAIL: debug write code leaked into another app file' >&2
  exit 1
else
  result=$?
  if [[ $result != 1 ]]; then echo 'FAIL: debug source search failed' >&2; exit 1; fi
fi
echo 'PASS: Sources has no file-changing calls'
