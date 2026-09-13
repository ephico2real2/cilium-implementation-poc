#!/usr/bin/env bash
# callers.sh <namespace/pod-prefix> <out.ndjson> [last] — the INGRESS request flows into a pod, whatever their verdict
# (cf2cnp reads flows, not verdicts: a DROPPED caller becomes a rule too, which is why the intent is reviewed before
# generating — E4), with one line per (caller, port, verdict, policy).
set -uo pipefail; cd "$(dirname "$0")/../.."; POD="${1:?namespace/pod}"; OUT="${2:?out.ndjson}"; LAST="${3:-300}"
hubble observe -P --kube-context kind-poc1 --to-pod "$POD" --last "$LAST" -o json 2>/dev/null | python3 -c '
import json,sys,collections
c=collections.OrderedDict(); n=0
with open(sys.argv[1],"w") as out:
    for l in sys.stdin:
        try: f=json.loads(l)["flow"]
        except Exception: continue
        if f.get("is_reply") or f.get("traffic_direction")!="INGRESS": continue
        l4=f.get("l4",{}); port=(l4.get("TCP") or l4.get("UDP") or {}).get("destination_port")
        by=(f.get("ingress_allowed_by") or f.get("ingress_denied_by") or [{}])[0].get("name","-")
        k=(f["source"].get("pod_name","?"), port, f["verdict"], by); c[k]=c.get(k,0)+1; out.write(l); n+=1
print("kept", n, "INGRESS request flows ->", sys.argv[1])
for (s,p,v,b),m in c.items(): print("  {:3} {} -> :{} {} {}".format(m, s, p, v, b))
' "$OUT"
