#!/usr/bin/env bash
# Usage: test_recap_counts.sh <demo dir>
# The check counts, retry count, secret list and readiness times in RECAP.md must come from the
# recorded run (output/transcript.txt), and the containers it says read `Up` from compose.yaml;
# the diagram source must name the published TLS port and no store as still to come.
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

if [ "${phases}" = "${got_phases}" ] && [ "${total}" = "${got_total}" ]; then
  check "counts: phases 1-3 ${phases}, whole run ${total}" 0
else
  check "counts: phases 1-3 ${phases}, whole run ${total}" 1
fi
# BACKLOG's VictoriaMetrics dashboard result is the one inside the comparison step, before phase 5
# creates the two status-update series. Drop only dashboard_queries.py's elapsed-time suffix.
vm_dashboard="$(awk '/^==== Compare Prometheus/{on=1; next} /^==== /{on=0} on' "${t}" \
  | sed -n 's/^\([0-9][0-9]* queries, [0-9][0-9]* with errors or warnings, [0-9][0-9]* empty\), .*$/\1/p' \
  | tail -1)"
grep -Fq "On VictoriaMetrics: \`${vm_dashboard}\`" "$1/docs/roadmap/BACKLOG.md"; check \
  "VictoriaMetrics dashboard: ${vm_dashboard}" "$?"
# The readiness gate's reads, and the chapter's parity table: the transcript's own.
gate_reads="$(grep -c '^rate window samples at T' "${t}")"
grep -Fq "(${gate_reads} checks)" "$1/docs/reviews/R1.3.md"; check \
  "readiness gate: ${gate_reads} reads in the transcript, named in the review record" "$?"
table_ok=0 rows=0
while IFS= read -r row; do
  rows=$((rows + 1))
  grep -Fq "${row}" "$1/docs/story/01-turn-the-lights-on.md" || table_ok=1
done < <(awk '/^Evaluation timestamp/{on=1} on && /  PASS$|  FAIL/{print}' "${t}" \
  | sed -n 's/^\(.\{58\}\) *\([0-9][0-9]*\) *\([0-9][0-9]*\) *\([^ ]*\) <= \([^ ]*\)  \(.*\)$/\1|\2|\3|\4|\5|\6/p' \
  | awk -F'|' '{sub(/ +$/, "", $1); printf "| %s | %s | %s | %s (allowed %s) | %s |\n", $1, $2, $3, $4, $5, $6}')
[ "${rows}" -eq 10 ] || table_ok=1
check "chapter parity table: the transcript's ${rows} rows" "${table_ok}"
grep -Fq "processed, after ${retries} Envoy retries." "$1/RECAP.md"; check \
  "retry delta: ${retry_before} -> ${retry_after} is ${retries}" "$?"
# The secrets the run wrote or kept, each named in step 2's result, and no other.
python3 - "${t}" "$1/RECAP.md" <<'PY'
import re
import sys
from pathlib import Path

section = Path(sys.argv[1]).read_text().split("==== Create the secrets", 1)[1].split("\n====", 1)[0]
recorded = set(re.findall(r"^(?:kept|created) +(\S+)", section, re.MULTILINE))
recap = " ".join(Path(sys.argv[2]).read_text().split())
sentence = recap.split("Result: `secrets/` holds", 1)[1].split("with the lab values", 1)[0]
named = set(re.findall(r"`([a-z-]+)`", sentence))
if not recorded or named != recorded:
    print(f"secrets: recorded {sorted(recorded)}, RECAP {sorted(named)}", file=sys.stderr)
    sys.exit(1)
PY
check "secret list: the run's own" "$?"
tr '\n' ' ' < "$1/RECAP.md" | grep -Fq "Envoy after ${envoy_s} s, Postgres after ${postgres_s} s, MQ after ${mq_s} s and Grafana after ${grafana_s} s."; check \
  "readiness: Envoy ${envoy_s}s, Postgres ${postgres_s}s, MQ ${mq_s}s, Grafana ${grafana_s}s" "$?"
grep -Fq 'connect to one port, 8443.' "$1/docs/diagrams/layers/source.html"; check \
  "edge diagram accessibility text uses port 8443" "$?"
! grep -Fq 'being added in R1.2' "$1/docs/diagrams/layers/source.html"; check \
  "high-level diagram text: the R1.2 stores are built" "$?"
# Every long-running service without a health check (no profile, not a one-shot) is named in the
# step that says which ones read `Up` rather than `healthy`.
python3 - "$1/compose.yaml" "$1/RECAP.md" <<'PY'
import re
import sys
from pathlib import Path

services, name = {}, None
for line in Path(sys.argv[1]).read_text().splitlines():
    if re.match(r"^\S", line):
        name = None
        in_services = line.startswith("services:")
    elif in_services and (m := re.match(r"^  ([a-z0-9-]+):\s*$", line)):
        name = m.group(1)
        services[name] = set()
    elif name and (m := re.match(r'^    (healthcheck:|profiles:|restart: "no")', line)):
        services[name].add(m.group(1))
without = sorted(n for n, keys in services.items() if not keys)
recap = " ".join(Path(sys.argv[2]).read_text().split())
sentence = recap.split("without a health check", 1)[1].split("read `Up`", 1)[0] if "without a health check" in recap else ""
missing = [n for n in without if f"`{n}`" not in sentence]
if not without or missing:
    print(f"no health check in compose.yaml: {without}; not named in RECAP: {missing}", file=sys.stderr)
    sys.exit(1)
PY
check "containers that read Up: compose.yaml's own" "$?"
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
# The fresh run's duration, from its first to its last step, is the one RECAP and run.sh state.
python3 - "${t}" "$1/RECAP.md" "$1/scripts/run.sh" <<'PY'
import re
import sys
from datetime import datetime
from pathlib import Path

stamps = re.findall(r"^==== .*\((\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\)$",
                    Path(sys.argv[1]).read_text(), re.MULTILINE)
first, last = (datetime.fromisoformat(stamp.replace("Z", "+00:00")) for stamp in (stamps[0], stamps[-1]))
seconds = int((last - first).total_seconds())
want = f"{seconds // 60} min {seconds % 60} s"
recap = re.search(r"^Result: (\d+ min \d+ s);", Path(sys.argv[2]).read_text(), re.MULTILINE)
header = re.search(r"^# Takes about \d+ minutes \((\d+ min \d+ s) recorded\)",
                   Path(sys.argv[3]).read_text(), re.MULTILINE)
got = (recap.group(1) if recap else None, header.group(1) if header else None)
if got != (want, want):
    print(f"duration: transcript {want}; RECAP {got[0]}; run.sh {got[1]}", file=sys.stderr)
    sys.exit(1)
PY
check "duration: the transcript's, in RECAP and run.sh's header" "$?"
echo "mismatches: ${bad}"; exit "${bad}"
