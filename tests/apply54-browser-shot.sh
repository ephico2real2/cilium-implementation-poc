#!/usr/bin/env bash
# test: apply.sh's browser_shot judges by the artefact — it returns as soon as the
# PNG exists (Chrome 153 writes it and never exits, gotcha #121; measured 1.40 s to
# the file, then a hang until the 60 s ceiling) and still bounds a Chrome that
# never writes. Fake Chrome: writes the file after 1 s, then sleeps.
# usage: bash tests/apply54-browser-shot.sh [demos/54-eg-poc1-kube-vip/apply.sh]   (exit 0 = pass)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
APPLY=${1:-$R/demos/54-eg-poc1-kube-vip/apply.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/demos/54-eg-poc1-kube-vip/output" "$T/bin"

cat > "$T/bin/fake-chrome" <<'STUB'
#!/usr/bin/env bash
# Chrome 153's shape: the screenshot lands, the process does not exit
shot=""
for a in "$@"; do case "$a" in --screenshot=*) shot=${a#--screenshot=} ;; esac; done
sleep 1
printf 'PNG' > "$shot"
sleep 300
STUB
chmod +x "$T/bin/fake-chrome"

sed -n '/^browser_shot() {/,/^}/p' "$APPLY" > "$T/browser_shot.sh"
grep -q 'browser_shot()' "$T/browser_shot.sh" || { echo "TEST FAIL: browser_shot() not found in $APPLY"; exit 1; }

start=$(date +%s)
out=$(cd "$T/repo" && CHROME="$T/bin/fake-chrome" HERE=demos/54-eg-poc1-kube-vip \
  HTTP_HOST=api.eg-poc1.poc.local HTTP_ADDR=172.19.255.100 PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash -c 'source ../browser_shot.sh; browser_shot' 2>&1)
rc=$?
elapsed=$(( $(date +%s) - start ))

[ -s "$T/repo/demos/54-eg-poc1-kube-vip/output/browser.png" ] \
  || { echo "TEST FAIL: no PNG after browser_shot (rc=$rc)"; printf '%s\n' "$out"; exit 1; }
if [ "$elapsed" -ge 30 ]; then
  echo "TEST FAIL: browser_shot took ${elapsed}s for a PNG that existed after 1 s (waits for Chrome instead of the file)"
  printf '%s\n' "$out"
  exit 1
fi
# no fake-chrome may survive the function
if pgrep -f "$T/bin/fake-chrome" >/dev/null 2>&1; then
  echo "TEST FAIL: fake-chrome still running after browser_shot returned"
  pkill -f "$T/bin/fake-chrome"
  exit 1
fi
echo "TEST PASS: browser_shot returned in ${elapsed}s with the PNG, Chrome killed"
exit 0
