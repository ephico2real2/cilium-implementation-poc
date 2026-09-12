#!/usr/bin/env bash
# collect.sh <demo dir> — record, through scripts/record.sh, the running pods of the demo's namespaces in both clusters
# and the Cilium/kubectl command that proves the demo's claim, into demos/<demo>/output/evidence.txt (overwritten).
# The per-demo table is in scripts/evidence/table.txt: "<demo dir>|<ctx:ns ctx:ns ...>|<extra command>|<extra command>..."
set -uo pipefail; cd "$(dirname "$0")/../.."; D="${1:?demo dir}"; T="$D/output/evidence.txt"; mkdir -p "$D/output"; : > "$T"
LINE=$(grep "^${D}|" scripts/evidence/table.txt) || { echo "no table entry for $D" >&2; exit 1; }
IFS='|' read -r _ NSLIST EXTRAS <<< "$LINE"
echo "# evidence for $D — recorded $(date -u +%Y-%m-%dT%H:%MZ) by scripts/evidence/collect.sh" >> "$T"
for pair in $NSLIST; do c="${pair%%:*}"; ns="${pair##*:}"; scripts/record.sh "$T" kubectl --context "kind-$c" -n "$ns" get pods -o wide >/dev/null 2>&1; done
if [ -n "${EXTRAS:-}" ]; then IFS='|' read -ra CMDS <<< "$EXTRAS"; for cmd in "${CMDS[@]}"; do [ -n "$cmd" ] && scripts/record.sh "$T" bash -c "$cmd" >/dev/null 2>&1; done; fi
echo "$(grep -c '^\$ ' "$T") commands recorded → $T"
