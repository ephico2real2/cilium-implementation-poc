#!/usr/bin/env bash
# verdicts-both.sh [last] — policy-verdict events into the five service namespaces, per cluster.
# Demo 35's verdicts.sh, generalised. 0 DROPPED on intended paths is the audit-then-enforce check.
#
#   demos/41-shop-mesh-phase1/verdicts-both.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
LAST="${1:-200}"
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

for ctx in "${CTX_ARR[@]}"; do
  echo "== $ctx"
  {
    for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
      hubble observe -P --kube-context "$ctx" --to-namespace "$ns" --type policy-verdict --last "$LAST" -o json 2>/dev/null
    done
  } | python3 -c '
import json,sys,collections
c=collections.OrderedDict()
def who(e):
    w=(e.get("workloads") or [{"name": e.get("pod_name","?")}])[0]
    return w.get("name","?")+"@"+e.get("namespace","?")
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("traffic_direction")!="INGRESS": continue
    by=(f.get("ingress_allowed_by") or f.get("ingress_denied_by") or [])
    k=(who(f["source"]), who(f["destination"]), f["verdict"], ",".join(x.get("name","?") for x in by) or "(no policy named)")
    c[k]=c.get(k,0)+1
if not c:
    print("  (no policy-verdict events)")
for (s,d,v,b),n in sorted(c.items(), key=lambda kv: (kv[0][1], kv[0][0], kv[0][2])):
    print("  {:3}  {:28} -> {:28} {:9} {}".format(n, s, d, v, b))
'
done
