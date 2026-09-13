#!/usr/bin/env bash
# l7-summary.sh [namespace] [last] — the HTTP flows of a namespace as the proxy reports them: one line per
# (source → destination, type, method, path, status, verdict, policy). REQUEST records are what cf2cnp --l7 reads;
# RESPONSE records carry the status code — a 403 from the proxy is the L7 denial itself.
set -uo pipefail; cd "$(dirname "$0")/../.."; NS="${1:-cf2cnp-lab30}"; LAST="${2:-300}"
hubble observe -P --kube-context kind-poc1 --namespace "$NS" --protocol http --last "$LAST" -o json 2>/dev/null | python3 -c '
import json,sys,collections
from urllib.parse import urlsplit
c=collections.OrderedDict()
def who(e): return e.get("pod_name","?").rsplit("-",2)[0] if e.get("pod_name","").count("-")>=2 else e.get("pod_name","?")
def by(f):
    for k in ("ingress_allowed_by","egress_allowed_by","ingress_denied_by","egress_denied_by"):
        if f.get(k): return k.replace("_by","")+"="+",".join(x.get("name","?") for x in f[k])
    return "-"
for l in sys.stdin:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    h=(f.get("l7") or {}).get("http") or {}
    if not h: continue
    u=urlsplit(h.get("url","")); path=u.path+("?"+u.query if u.query else "")
    k=(who(f["source"]), who(f["destination"]), f["l7"].get("type"), h.get("method"), path, h.get("code",""), f.get("traffic_direction","-"), f.get("verdict"), by(f))
    c[k]=c.get(k,0)+1
row="{:>3} {:28} {:9} {:7} {:22} {:5} {:9} {:10} {}"
print(row.format("n","source → destination","type","method","path","code","direction","verdict","policy"))
for (s,d,t,m,p,code,dr,v,b),n in c.items(): print(row.format(n, s+" → "+d, t, m or "", p, str(code), dr, v, b))
'
