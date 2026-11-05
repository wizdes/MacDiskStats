#!/bin/zsh
set -euo pipefail
source_file=${1:-Sources/DiskCore/Scanner.swift}
python3 - "$source_file" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
required=['job.rawPath ? -1 : openat', 'if job.rawPath || fd < 0', 'rawPath = rawPath || decoded == nil', 'rawPath: rawPath']
if not all(piece in text for piece in required):
    print('FAIL bug: invalid UTF-8 directory name reopens through display text')
    sys.exit(1)
print('PASS bug: invalid UTF-8 directory name reopens through raw bytes')
PY
