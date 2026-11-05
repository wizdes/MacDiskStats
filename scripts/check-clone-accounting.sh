#!/bin/zsh
set -euo pipefail
source_file=${1:-Sources/DiskCore/Scanner.swift}
python3 - "$source_file" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
part=text.split('func add(_ e: Entry,',1)[1].split('lock.lock()',1)[0]
clone=part.find('e.cloneRefs > 1')
private_zero=part.find('privateSize = 0')
if clone < 0 or private_zero < clone:
    print('FAIL bug: hard linked clone loses private bytes before clone accounting')
    sys.exit(1)
print('PASS bug: hard linked clone keeps private bytes for clone accounting')
PY
