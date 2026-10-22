#!/usr/bin/env bash
# Usage: test_recap_counts.sh <demo dir>
# The check counts, retry count, secret list and readiness times in RECAP.md must come from the
# recorded run (output/transcript.txt); the diagram source must name the published TLS port.
set -u
t="$1/output/transcript.txt"
phases="$(awk '/^==== Check phases 1-3/{on=1; next} /^==== /{on=0} on' "${t}" | grep -c '^PASS')"
total="$(grep -c '^PASS' "${t}")"
got_phases="$(sed -n 's/^Result: phases 1 to 3, \([0-9]*\) checks.*/\1/p' "$1/RECAP.md")"
got_total="$(sed -n 's/^Result: [0-9]* min [0-9]* s; \([0-9]*\) checks pass.*/\1/p' "$1/RECAP.md")"
retry_before="$(sed -n 's/.*upstream_rq_retry \([0-9]*\) -> \([0-9]*\).*/\1/p' "${t}")"
retry_after="$(sed -n 's/.*upstream_rq_retry \([0-9]*\) -> \([0-9]*\).*/\2/p' "${t}")"
retries=$((retry_after - retry_before))
envoy_s="$(sed -n 's/^envoy  *healthy after \([0-9]*\)s/\1/p' "${t}")"
postgres_s="$(sed -n 's/^postgres  *healthy after \([0-9]*\)s/\1/p' "${t}")"
mq_s="$(sed -n 's/^mq  *healthy after \([0-9]*\)s/\1/p' "${t}")"
grafana_s="$(sed -n 's/^grafana  *healthy after \([0-9]*\)s/\1/p' "${t}")"

bad=0
check() {  # check <description> <command status: 0 means match>
  local description="$1" status="$2" verdict=ok
  if [ "${status}" -ne 0 ]; then verdict=MISMATCH; bad=$((bad + 1)); fi
  printf '%-9s %s\n' "${verdict}" "${description}"
}

[ "${phases}" = "${got_phases}" ] && [ "${total}" = "${got_total}" ]; check \
  "counts: phases 1-3 ${phases}, whole run ${total}" "$?"
grep -Fq "processed, after ${retries} Envoy retries." "$1/RECAP.md"; check \
  "retry delta: ${retry_before} -> ${retry_after} is ${retries}" "$?"
# shellcheck disable=SC2016  # the backticks are Markdown, searched for literally
grep -Fq '`grafana-admin-password` and `worker-token`' "$1/RECAP.md"; check \
  "secret list includes worker-token" "$?"
tr '\n' ' ' < "$1/RECAP.md" | grep -Fq "Envoy after ${envoy_s} s, Postgres after ${postgres_s} s, MQ after ${mq_s} s and Grafana after ${grafana_s} s."; check \
  "readiness: Envoy ${envoy_s}s, Postgres ${postgres_s}s, MQ ${mq_s}s, Grafana ${grafana_s}s" "$?"
grep -Fq 'connect to one port, 8443.' "$1/docs/diagrams/layers/source.html"; check \
  "edge diagram accessibility text uses port 8443" "$?"
python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
blocks = re.findall(r"```text\n(.*?)```", (root / "README.md").read_text(), re.DOTALL)
records = [path.read_text() for path in (root / "output").glob("*.txt")]
missing = [str(index) for index, block in enumerate(blocks, 1)
           if not any(block in record for record in records)]
if missing:
    print("README text blocks absent from output files: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY
check "README text blocks are exact recorded slices" "$?"
echo "mismatches: ${bad}"; exit "${bad}"
