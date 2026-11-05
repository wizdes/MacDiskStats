#!/bin/zsh
set -euo pipefail
runner=${1:-scripts/test-all.sh}
runner=$(cd "$(dirname "$runner")" && pwd)/$(basename "$runner")
fixture=$(mktemp -d build/tmp/mds-runner-test.XXXXXX)
trap 'rm -r "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/build/tmp" "$fixture/docs" "$fixture/bin" "$fixture/build/MacDiskStats.app/Contents/MacOS"
cp "$runner" "$fixture/scripts/test-all.sh"
cat > "$fixture/scripts/build.sh" <<'SCRIPT'
#!/bin/zsh
mkdir -p build/release/MacDiskStats.app/Contents/MacOS
: > build/release/MacDiskStats.app/Contents/MacOS/MacDiskStats
: > build/release/macdiskstats-bench
SCRIPT
cat > "$fixture/build/checks" <<'SCRIPT'
#!/bin/zsh
print 'PASS fake unit'
print "checks 1, failed ${UNIT_SUMMARY_FAIL:-0}"
exit ${UNIT_EXIT:-0}
SCRIPT
cat > "$fixture/build/MacDiskStats.app/Contents/MacOS/MacDiskStats" <<'SCRIPT'
#!/bin/zsh
print 'PASS e2e: fake app'
print 'E2E DELETE NOW'
sleep 0.1
print 'e2e 1 passed, 0 failed'
SCRIPT
cat > "$fixture/bin/nm" <<'SCRIPT'
#!/bin/zsh
exit ${NM_EXIT:-0}
SCRIPT
cat > "$fixture/bin/strings" <<'SCRIPT'
#!/bin/zsh
exit ${STRINGS_EXIT:-0}
SCRIPT
cat > "$fixture/bin/rg" <<'SCRIPT'
#!/bin/zsh
if [[ ${RG_EXIT:-0} != 0 && $1 == '^_(unlink|'* ]]; then exit "$RG_EXIT"; fi
exec "$REAL_RG" "$@"
SCRIPT
for name in test-icon.sh check-readonly.sh check-scanner-races.sh check-clone-accounting.sh check-raw-path.sh check-entitlements.sh sandbox-probe.sh test-runner-failures.sh; do
  cat > "$fixture/scripts/$name" <<'SCRIPT'
#!/bin/zsh
exit 0
SCRIPT
done
chmod +x "$fixture/scripts/"*.sh "$fixture/build/checks" "$fixture/build/MacDiskStats.app/Contents/MacOS/MacDiskStats" "$fixture/bin/"*
fail=0
real_rg=$(command -v rg)
for kind in unit summary nm strings search; do
  case "$kind" in
    unit) unit=7; summary=0; nm=0; strings=0; search=0;;
    summary) unit=0; summary=1; nm=0; strings=0; search=0;;
    nm) unit=0; summary=0; nm=7; strings=0; search=0;;
    strings) unit=0; summary=0; nm=0; strings=7; search=0;;
    search) unit=0; summary=0; nm=0; strings=0; search=7;;
  esac
  if (cd "$fixture" && PATH="$(pwd)/bin:$PATH" UNIT_EXIT=$unit UNIT_SUMMARY_FAIL=$summary NM_EXIT=$nm STRINGS_EXIT=$strings RG_EXIT=$search REAL_RG=$real_rg zsh scripts/test-all.sh > "runner-$kind.log" 2>&1); then result=0
  else result=$?; fi
  if (( result == 0 )); then print "FAIL bug: test runner accepts failed $kind command"; fail=$((fail+1))
  else print "PASS bug: test runner rejects failed $kind command"; fi
done
print "runner failure checks 5, failed $fail"
(( fail == 0 ))
