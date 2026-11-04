#!/bin/zsh
set -euo pipefail
python3 - <<'PY'
import plistlib
with open('Resources/Cushion.entitlements', 'rb') as f:
    entitlements = plistlib.load(f)
assert entitlements == {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/'],
}, entitlements
print('PASS: release entitlements have sandbox and only the read-only root exception')
PY
