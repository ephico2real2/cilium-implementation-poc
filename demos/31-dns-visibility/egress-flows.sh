#!/usr/bin/env bash
# egress-flows.sh <pod> <out.ndjson> [last] — every EGRESS request flow of a pod (replies skipped, the LATEST flow per
# destination:port kept — cf2cnp merges duplicates anyway, and the newest one carries what the pod's policy does NOW),
# and a summary with the names Hubble attached, if any.
# destination_names is empty until a DNS-visibility rule puts the pod's lookups through the DNS proxy (E3).
set -uo pipefail; cd "$(dirname "$0")/../.."; POD="${1:?namespace/pod}"; OUT="${2:?out.ndjson}"; LAST="${3:-300}"
hubble observe -P --kube-context kind-poc1 --from-pod "$POD" --last "$LAST" -o json 2>/dev/null | python3 -c '
import json,sys
seen={}; lines={}
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("is_reply") or f.get("traffic_direction")!="EGRESS": continue
    l4=f.get("l4",{}); proto="TCP" if "TCP" in l4 else "UDP" if "UDP" in l4 else "?"; port=(l4.get(proto) or {}).get("destination_port")
    d=f["destination"]; key=(d.get("pod_name") or ",".join(x for x in d.get("labels",[]) if x.startswith("reserved:")) or f["IP"]["destination"], port, proto)
    seen[key]=f; lines[key]=l
with open(sys.argv[1],"w") as out: out.writelines(lines.values())
print("kept", len(seen), "request flows ->", sys.argv[1])
for (d,port,proto),f in seen.items(): print("  {}:{}/{:3}  ip={:16} names={}  {}".format(d, port, proto, f["IP"]["destination"], f.get("destination_names") or "-", f["verdict"]))
' "$OUT"
