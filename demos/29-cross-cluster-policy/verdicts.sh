#!/usr/bin/env bash
# verdicts.sh [last] — the policy-verdict events at the cache (poc1) and at worker@poc2's egress (poc2's node), one line per
# (node, source@cluster → destination@cluster:port, verdict, the policy that decided). A default-deny drop names no policy
# (gotcha #82); an allow names the generated one.
set -uo pipefail; cd "$(dirname "$0")/../.."; LAST="${1:-100}"
hubble observe -P --kube-context kind-poc1 --namespace mesh-lab --type policy-verdict --last "$LAST" -o json 2>/dev/null | python3 -c '
import json,sys,collections; c=collections.OrderedDict()
def who(e): return (e.get("pod_name") or e.get("namespace","?"))+"@"+e.get("cluster_name","-")
def by(f):
    for k in ("ingress_allowed_by","egress_allowed_by","ingress_denied_by","egress_denied_by"):
        v=f.get(k)
        if v: return k.replace("_by","")+"="+",".join(x.get("name","?") for x in v)
    return "(no policy named)"
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    l4=f.get("l4",{}); port=(l4.get("TCP") or l4.get("UDP") or {}).get("destination_port")
    k=(f.get("node_name","?"), f.get("traffic_direction","-"), who(f["source"]), who(f["destination"]), port, f.get("verdict"), by(f))
    c[k]=c.get(k,0)+1
for (n,d,s,t,p,v,b),m in c.items(): print(f"{m:3} {n:19} {d:8} {s} → {t}:{p} {v} {b}")
'
