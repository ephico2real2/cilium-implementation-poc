#!/usr/bin/env bash
# test: demo 46-colima's clear_and_watch prints the recovery WINDOW the events
# show (first spine Idle → last spine Established) and does not label the
# poll-loop notice as "recovered after".
# usage: bash tests/apply46-colima-recovery-window.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
APPLY=$R/demos/46-bgp-fabric-colima/apply.sh
fails=0
# the needle is the forbidden apply.sh string, not a shell expansion.
# shellcheck disable=SC2016
if grep -q 'echo "recovered after \${rec_elapsed} s"' "$APPLY"; then
  echo "FAIL: apply.sh still labels the loop's notice time as 'recovered after'"
  fails=$((fails + 1))
fi
awk '/^  MARK="\$mark" /{p=1} p{print} /^PY$/{if(p){p=0}}' "$APPLY" > "$T/block.py"
# the heredoc python between python3 - <<'PY' and PY
awk '/python3 - <<'"'"'PY'"'"'/{p=1; next} /^PY$/{p=0} p' "$APPLY" > "$T/block.py"
[ -s "$T/block.py" ] || { echo "FAIL: could not extract the event block from apply.sh"; exit 1; }
cat > "$T/events.json" <<'JSON'
[{"id":1,"ts":"2026-09-20T14:01:39.210Z","kind":"session","router":"spine","peer":"10.200.1.2","from":"Established","to":"Idle","text":"spine 10.200.1.2 Established → Idle"},
 {"id":2,"ts":"2026-09-20T14:01:39.210Z","kind":"session","router":"spine","peer":"10.200.1.19","from":"Established","to":"Idle","text":"spine 10.200.1.19 Established → Idle"},
 {"id":3,"ts":"2026-09-20T14:01:41.209Z","kind":"session","router":"spine","peer":"10.200.1.2","from":"Idle","to":"Established","text":"spine 10.200.1.2 Idle → Established"},
 {"id":4,"ts":"2026-09-20T14:01:41.209Z","kind":"session","router":"spine","peer":"10.200.1.19","from":"OpenConfirm","to":"Established","text":"spine 10.200.1.19 OpenConfirm → Established"}]
JSON
out=$(cd "$T" && MARK=0 DASH=http://127.0.0.1:8098 python3 -c '
import io, sys, urllib.request
fixture = open("events.json", "rb").read()
urllib.request.urlopen = lambda *a, **k: io.BytesIO(fixture)
exec(open("block.py").read())
' 2>&1)
line=$(printf '%s\n' "$out" | grep '^spine recovery:')
case "$line" in
  *'first Idle 2026-09-20T14:01:39.210Z last Established 2026-09-20T14:01:41.209Z recovered=yes window=1.999 s'*) echo "ok: $line" ;;
  *) echo "FAIL: expected the 1.999 s window on the spine recovery line, got: ${line:-<none>}"; printf '%s\n' "$out" | tail -3; fails=$((fails + 1)) ;;
esac
[ "$fails" -eq 0 ] || { echo "TEST FAIL: $fails"; exit 1; }
echo "TEST PASS: colima apply prints the event window (first Idle → last Established) and no longer labels the notice time 'recovered after'"
