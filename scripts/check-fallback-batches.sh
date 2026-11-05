#!/bin/zsh
set -euo pipefail
source_file=${1:-Sources/DiskCore/Scanner.swift}
python3 - "$source_file" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
part = text.split('private func fallback(', 1)[1].split('private func finish(', 1)[0]
if 'batchCount == 256' not in part or part.count('s.addLiveAncestors(batchBytes, below: job.id)') < 2:
    print('FAIL bug: fallback keeps ancestor bytes until whole directory finishes')
    sys.exit(1)
print('PASS bug: fallback publishes ancestor bytes per batch')
PY
