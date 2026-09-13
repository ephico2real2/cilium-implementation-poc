#!/usr/bin/env bash
# loki-verdicts.sh [range] — the policy-verdict stream as Loki holds it (E8): how many lines the second observer's
# container label carries, one raw line with its allowed_by block, and the question the stream exists to answer —
# "which policy allowed it" — as a LogQL aggregation over the range (default 15m). Loki is reached by port-forward.
set -uo pipefail; cd "$(dirname "$0")/../.."; R="${1:-15m}"
kubectl --context kind-poc1 -n monitoring port-forward svc/loki 23100:3100 >/dev/null 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 2
q() { curl -s -G http://127.0.0.1:23100/loki/api/v1/query --data-urlencode "query=$1"; }
echo "== lines per container label, last $R"
for c in hubble-observer hubble-observer-verdicts; do
  printf '   %-26s %s\n' "$c" "$(q "sum(count_over_time({namespace=\"hubble-observer\", container=\"$c\"}[$R]))" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)')"
done
echo "== one policy-verdict line, the fields that matter"
curl -s -G http://127.0.0.1:23100/loki/api/v1/query_range --data-urlencode 'query={namespace="hubble-observer", container="hubble-observer-verdicts"} | json verdict="flow.verdict", allowed_by="flow.ingress_allowed_by[0].name" | verdict="FORWARDED" | allowed_by != ""' --data-urlencode 'limit=1' | python3 -c '
import json,sys
r=json.load(sys.stdin)["data"]["result"]
if not r: print("   (none yet)"); sys.exit()
f=json.loads(r[0]["values"][0][1])["flow"]
print("  ", f["source"].get("pod_name"), "->", f["destination"].get("pod_name"), f.get("verdict"), f.get("traffic_direction"))
print("   ingress_allowed_by:", json.dumps(f.get("ingress_allowed_by")))'
echo "== which policy allowed it (ingress), last $R"
q "sum by (allowed_by) (count_over_time({namespace=\"hubble-observer\", container=\"hubble-observer-verdicts\"} | json allowed_by=\"flow.ingress_allowed_by[0].name\" | allowed_by != \"\" [$R]))" | python3 -c '
import json,sys
for r in sorted(json.load(sys.stdin)["data"]["result"], key=lambda r: -float(r["value"][1])): print("   {:>6}  {}".format(r["value"][1], r["metric"].get("allowed_by")))'
echo "== which policy denied it, and the unnamed drops (default-deny), last $R"
q "sum by (denied_by) (count_over_time({namespace=\"hubble-observer\", container=\"hubble-observer-verdicts\"} | json denied_by=\"flow.ingress_denied_by[0].name\", verdict=\"flow.verdict\" | verdict=\"DROPPED\" [$R]))" | python3 -c '
import json,sys
for r in json.load(sys.stdin)["data"]["result"]: print("   {:>6}  {}".format(r["value"][1], r["metric"].get("denied_by") or "(no policy named — a default-deny drop, gotcha #82)"))'
