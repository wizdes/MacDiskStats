#!/bin/zsh
set -uo pipefail
mkdir -p build/tmp
export TMPDIR="$(cd build/tmp && pwd)/"
start=$SECONDS
pass=0
fail=0
record() {
  if [[ $2 == 0 ]]; then print "PASS $1"; (( pass++ ))
  else print "FAIL $1"; (( fail++ ))
  fi
}
finish() {
  local total=$((pass+fail))
  print "tests $total, passed $pass, failed $fail"
  print "$(date -u +%Y-%m-%d),$(git rev-parse --short HEAD),merge,$total,$((SECONDS-start))" >> docs/test-times.csv
  (( fail == 0 && total > 0 ))
}
scripts/build.sh debug > build/test-debug-build.log 2>&1
record 'debug swiftc build' $?
if (( fail == 0 )); then
  scripts/test-icon.sh > build/test-icon.log 2>&1
  record 'icon generation' $?
  build/checks > build/test-unit.log 2>&1
  cat build/test-unit.log
  if [[ -n $(find "$TMPDIR" -maxdepth 1 -name 'macdiskstats-checks-*' -print -quit) ]]; then record 'unit fixtures cleaned after checks' 1
  else record 'unit fixtures cleaned after checks' 0; fi
  unitPass=$(rg -c '^PASS ' build/test-unit.log || true)
  unitFail=$(rg -c '^FAIL ' build/test-unit.log || true)
  (( pass += ${unitPass:-0}, fail += ${unitFail:-0} ))
  if (( ${unitPass:-0} == 0 )) || rg -q '^SKIP ' build/test-unit.log; then record 'unit tests neither zero nor skipped' 1; fi
  if ! rg -q '^checks [1-9][0-9]*, failed [0-9]+$' build/test-unit.log; then record 'unit count present' 1; fi
  fixture=$(mktemp -d "${TMPDIR}mds-e2e.XXXXXX")
  mkdir -p "$fixture/nested"
  dd if=/dev/zero of="$fixture/large.txt" bs=4096 count=8 2>/dev/null
  dd if=/dev/zero of="$fixture/nested/other.png" bs=4096 count=4 2>/dev/null
  dd if=/dev/zero of="$fixture/delete-me.txt" bs=4096 count=1 2>/dev/null
  mkdir -p "$fixture"/nested/dir{1..10000}
  build/MacDiskStats.app/Contents/MacOS/MacDiskStats --e2e fixture --scan "$fixture" > build/test-e2e.log 2>&1 &
  appPID=$!
  for ((i=0; i<200; i++)); do
    if rg -q '^E2E DELETE NOW$' build/test-e2e.log; then break; fi
    if ! kill -0 $appPID 2>/dev/null; then break; fi
    sleep 0.05
  done
  rm "$fixture/delete-me.txt"
  wait $appPID
  e2eExit=$?
  cat build/test-e2e.log
  e2ePass=$(rg -c '^PASS e2e:' build/test-e2e.log || true)
  e2eFail=$(rg -c '^FAIL e2e:' build/test-e2e.log || true)
  (( pass += ${e2ePass:-0}, fail += ${e2eFail:-0} ))
  if rg -q '^SKIP ' build/test-e2e.log; then record 'e2e has no skipped checks' 1; fi
  if (( e2eExit != 0 || ${e2ePass:-0} == 0 )) || ! rg -q '^e2e [1-9][0-9]* passed, [0-9]+ failed$' build/test-e2e.log; then record 'e2e completed with count' 1; fi
  rm -r "$fixture"
fi
scripts/check-readonly.sh > build/test-source-readonly.log 2>&1
record 'source read-only scan' $?
scripts/check-entitlements.sh > build/test-entitlements.log 2>&1
record 'release entitlements' $?
scripts/build.sh release --out build/release > build/test-release-build.log 2>&1
record 'release swiftc build' $?
if [[ -f build/release/MacDiskStats.app/Contents/MacOS/MacDiskStats ]]; then
  binary=build/release/MacDiskStats.app/Contents/MacOS/MacDiskStats
  nm -u "$binary" > build/test-imports.log
  denied='^_(unlink|unlinkat|rename|renameat|renamex_np|rmdir|clonefile|truncate|ftruncate|mkdir|mkdirat|pwrite|pwritev|copyfile|remove|setxattr|fsetxattr|removexattr|chmod|chown|utimes)$'
  if rg "$denied" build/test-imports.log; then record 'release imports no file writes' 1
  else record 'release imports no file writes' 0; fi
  if strings "$binary" | rg 'DebugSnapshot|--e2e|snapshot saved'; then record 'release excludes debug snapshot and e2e' 1
  else record 'release excludes debug snapshot and e2e' 0; fi
  print "release imports: $(wc -l < build/test-imports.log)"
fi
finish
