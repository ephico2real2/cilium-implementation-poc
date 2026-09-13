#!/usr/bin/env bash
# flows-summary.sh [namespace] [last] — the REQUEST flows of a namespace as poc1's relay streams them for the whole mesh
# (demo 24), one line per (node, direction, source@cluster → destination@cluster:port, verdict): which node saw what.
# Replies are skipped (they carry the ephemeral port), so are ports other than the lab's (6379 and DNS).
set -uo pipefail; cd "$(dirname "$0")/../.."; NS="${1:-mesh-lab}"; LAST="${2:-400}"
hubble observe -P --kube-context kind-poc1 --namespace "$NS" --last "$LAST" -o json 2>/dev/null | python3 -c '
import json,sys,collections
seen=collections.OrderedDict()
def who(e):
    name=e.get("pod_name") or ",".join(x for x in e.get("labels",[]) if x.startswith("reserved:")) or e.get("namespace","?")
    return name+"@"+e.get("cluster_name","-")
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("is_reply"): continue
    l4=f.get("l4",{}); port=(l4.get("TCP") or l4.get("UDP") or {}).get("destination_port")
    if port not in (6379,53): continue
    k=(f.get("node_name","?"), f.get("traffic_direction","-"), who(f["source"]), who(f["destination"]), port, f.get("verdict","?"), f.get("Type",""))
    seen[k]=seen.get(k,0)+1
print("node                direction  source@cluster → destination@cluster:port              verdict    type  n")
for (n,dr,s,d,p,v,t),c in seen.items(): print(f"{n:19} {dr:9}  {s} → {d}:{p:<5} {v:9} {t:5} {c}")
'
