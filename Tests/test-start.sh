#!/bin/zsh
set -euo pipefail
log=build/test-start.log
mkdir -p build/tmp
fixture=$(mktemp -d "$(pwd)/build/tmp/mds-start.XXXXXX")
trap 'rm -r "$fixture"' EXIT
build/MacDiskStats.app/Contents/MacOS/MacDiskStats --e2e start --scan "$fixture" > "$log" 2>&1
cat "$log"
rg -q '^e2e [1-9][0-9]* passed, 0 failed$' "$log"
for name in 'empty layout is present before scan' 'path bar absent before scan' 'scan sheet is attached at launch' 'cancel keeps empty layout' 'New Scan reopens sheet' 'sheet Scan keeps the same layout' 'progress fill matches 47 percent' 'progress pixels show actual fill' 'progress does not cover scanning text' 'large Size fits with spinner' 'one disk uses one list row' 'Scan is the default button' 'volume icon uses backing scale' 'repeated Cmd-N keeps one sheet' 'Escape closes start sheet' 'Cmd-N with sheet open does not queue another' 'Return starts selected scan' 'reopen sheet after scan cancellation' 'Choose Folder replaces start sheet' 'Cmd-N cannot queue behind folder picker' 'closing window with sheet open closes window'; do
  rg -q "^PASS e2e: bug: $name$" "$log"
done
