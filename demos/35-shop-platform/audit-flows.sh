#!/usr/bin/env bash
# audit-flows.sh <out.ndjson> [last] — the AUDIT INGRESS request flows into every shop service namespace, as poc1's relay
# streams them, saved as one file (cf2cnp takes flows for many workloads and namespaces in one request), with a summary
# per (caller@namespace → service@namespace:port). Replies are skipped; nothing is filtered by intent here — Part 3 does that.
set -uo pipefail; cd "$(dirname "$0")/../.."; OUT="${1:?out.ndjson}"; LAST="${2:-300}"
: > "$OUT"
for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
  hubble observe -P --kube-context kind-poc1 --to-namespace "$ns" --verdict AUDIT --last "$LAST" -o json 2>/dev/null >> "$OUT"
done
python3 - "$OUT" <<'PY'
import json,sys,collections
c=collections.OrderedDict(); n=0
for l in open(sys.argv[1]):
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("is_reply") or f.get("traffic_direction")!="INGRESS": continue
    s,d=f["source"],f["destination"]
    def who(e): return (e.get("workloads") or [{"name": e.get("pod_name","?")}])[0]["name"]+"@"+e.get("namespace","?")
    l4=f.get("l4",{}); port=(l4.get("TCP") or {}).get("destination_port")
    k=(who(s), who(d), port); c[k]=c.get(k,0)+1; n+=1
print(n, "AUDIT INGRESS request flows ->", sys.argv[1])
for (s,d,p),m in sorted(c.items(), key=lambda kv: (kv[0][1], kv[0][0])): print("  {:3}  {:28} -> {}:{}".format(m, s, d, p))
PY
