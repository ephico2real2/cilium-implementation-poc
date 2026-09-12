#!/usr/bin/env bash
# drops.sh [since] — what Hubble DENIED in the bank namespace, both clusters, with the policy that denied it
# (hubble-network-policy-correlation-enabled=true fills ingress_denied_by / egress_denied_by).
SINCE="${1:-5m}"
for C in poc1 poc2; do
  hubble observe -P --kube-context kind-$C --namespace bank --verdict DROPPED --since "$SINCE" -o json 2>/dev/null | C=$C python3 -c '
import json,sys,os,collections; c=collections.Counter()
def who(e):
    l=e.get("labels",[]); a=next((x.split("=")[1] for x in l if x.startswith(("k8s:app=","k8s:k8s-app="))),None)
    return (a or next((x for x in l if x.startswith("reserved:")),"?")) + ("@"+e["cluster_name"] if e.get("cluster_name") else "")
for line in sys.stdin:
    f=json.loads(line).get("flow",{}); l4=f.get("l4",{}); p=(l4.get("TCP") or l4.get("UDP") or {}).get("destination_port")
    by=tuple(x.get("name") for x in (f.get("ingress_denied_by") or f.get("egress_denied_by") or []))
    c[(who(f["source"]), who(f["destination"]), p, f.get("drop_reason_desc"), "ingress" if f.get("ingress_denied_by") else "egress" if f.get("egress_denied_by") else "-", by)]+=1
print("== %s: %d dropped flows ==" % (os.environ["C"], sum(c.values())))
for k,n in c.most_common(10): print("  %4d  %-24s -> %-24s :%-5s %-22s %s denied_by=%s" % (n,k[0],k[1],k[2],k[3],k[4],list(k[5])))'
done
