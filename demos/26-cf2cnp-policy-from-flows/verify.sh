#!/usr/bin/env bash
# verify.sh — what the lab's traffic looks like right now, as Hubble sees it: verdict per (source → destination:port),
# with the policy that allowed or denied it (policy correlation is on: ingress_allowed_by / egress_denied_by …).
set -uo pipefail; cd "$(dirname "$0")/../.."
echo "policies in cf2cnp-lab: $(kubectl --context kind-poc1 -n cf2cnp-lab get cnp -o name 2>/dev/null | tr '\n' ' ')"
hubble observe -P --kube-context kind-poc1 $(scripts/hubble-tls.sh kind-poc1) --namespace cf2cnp-lab --since "${1:-2m}" -o json 2>/dev/null | python3 -c '
import json,sys,collections; c=collections.Counter()
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("is_reply"): continue
    s=f["source"].get("pod_name") or ",".join(f["source"].get("labels",[]))[:30]; d=f["destination"].get("pod_name") or (f.get("destination_names") or [","+",".join(f["destination"].get("labels",[]))[:30]])[0]
    port=(f.get("l4",{}).get("TCP") or f.get("l4",{}).get("UDP") or {}).get("destination_port")
    by=[p["name"] for p in (f.get("ingress_allowed_by") or f.get("egress_allowed_by") or f.get("ingress_denied_by") or f.get("egress_denied_by") or [])]
    c[(s,d,port,f["verdict"],f.get("drop_reason_desc") or "",",".join(by))]+=1
for k,n in sorted(c.items(), key=lambda x:-x[1])[:14]: print("  %4d  %-10s → %-32s :%-5s %-9s %-14s %s" % (n,k[0],k[1],k[2],k[3],k[4],("by "+k[5]) if k[5] else ""))'
