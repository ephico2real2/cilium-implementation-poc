#!/usr/bin/env bash
# test: the shared browser_shot must echo the same command line the demos
# already recorded — demo 54's README and transcript quote it verbatim, so a
# change to the echo silently invalidates a published block. The expected
# flag segment is read out of each demo's own transcript, not hard-coded.
#   usage: bash tests/browser-shot-recorded.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$T/chrome"
chmod +x "$T/chrome"

# the flags a recorded line carries between --user-data-dir=<tmp> and --screenshot=
segment_of() { # transcript flag
  grep -F -- "$2" "$1" | grep -F -- '--headless=new' | tail -1 \
    | sed -e 's/^.*--user-data-dir=<tmp> //' -e 's/ --screenshot=.*$//'
}

shot_line() { # runs browser_shot with a stub Chrome, prints its echoed line
  # no `| head`: browser_shot keeps writing and a closed pipe would SIGPIPE it
  local out
  out=$(cd "$R" && env "$@" CHROME="$T/chrome" \
      BROWSER_SHOT_PATH="$T/shot.png" BROWSER_SHOT_FILE_LABEL="$T/shot.png" \
      bash -c '. demos/shared/browser-shot.sh; browser_shot' 2>/dev/null)
  printf '%s\n' "$out" | sed -n 1p
}

fails=0
want54=$(segment_of "$R/demos/54-eg-poc1-kube-vip/output/transcript.txt" '--host-resolver-rules')
got54=$(shot_line HTTP_HOST=api.eg-poc1.poc.local HTTP_ADDR=172.19.255.100 \
  BROWSER_SHOT_WIDTH=1000 BROWSER_SHOT_HEIGHT=500 \
  BROWSER_SHOT_URL=http://api.eg-poc1.poc.local/orders \
  | sed -e 's/^.*--user-data-dir=<tmp> //' -e 's/ --screenshot=.*$//')
if [ "$got54" != "$want54" ]; then
  echo "FAIL demo 54 flags changed"
  echo "  recorded: $want54"
  echo "  now:      $got54"
  fails=$((fails + 1))
else
  echo "ok demo 54: $got54"
fi

want46=$(segment_of "$R/demos/46-bgp-fabric/output/transcript.txt" '--virtual-time-budget')
got46=$(shot_line BROWSER_SHOT_WIDTH=1200 BROWSER_SHOT_HEIGHT=700 \
  BROWSER_SHOT_VIRTUAL_TIME_MS=4000 BROWSER_SHOT_URL='http://127.0.0.1:8088/?router=spine' \
  | sed -e 's/^.*--user-data-dir=<tmp> //' -e 's/ --screenshot=.*$//')
if [ "$got46" != "$want46" ]; then
  echo "FAIL demo 46 flags changed"
  echo "  recorded: $want46"
  echo "  now:      $got46"
  fails=$((fails + 1))
else
  echo "ok demo 46: $got46"
fi

[ "$fails" -eq 0 ] || { echo "TEST FAIL: $fails"; exit 1; }
echo "TEST PASS: browser_shot echoes the recorded command line for demos 54 and 46"
