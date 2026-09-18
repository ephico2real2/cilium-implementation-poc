#!/usr/bin/env bash
# check.sh — prove every non-text panel's first query returns series from the lab Prometheus. Exit 0 by design:
# a line says `NO DATA` when N = 0; the report counts those words.
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }
CA="${ROOT_CA:-.tmp/root-ca.crt}"
PW=$(k -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
G="https://grafana.poc.local"

PROM=$(curl -s -u "admin:$PW" --cacert "$CA" "$G/api/datasources" | python3 -c '
import json,sys
ds=json.load(sys.stdin)
print(next((d["uid"] for d in ds if d.get("type")=="prometheus"), ""))
')
[ -n "$PROM" ] || echo "  prometheus uid: ?"

# title<TAB>expr — $cluster/$node/$namespace/$__rate_interval resolved, then URL-encoded
encode() {
  python3 -c 'import urllib.parse,sys
e=sys.argv[1]
for a,b in (("$cluster",".*"),("$node",".*"),("$namespace",".*"),("$__rate_interval","5m")):
    e=e.replace(a,b)
print(urllib.parse.quote(e, safe=""))
' "$1"
}

for uid in tut-1-question tut-2-time tut-3-colour tut-4-meaning tut-5-grow tut-6-cilium; do
  echo "== $uid"
  while IFS=$'\t' read -r title expr; do
    [ -n "${title:-}" ] || continue
    q=$(encode "$expr")
    n=$(curl -s -u "admin:$PW" --cacert "$CA" "$G/api/datasources/proxy/uid/${PROM}/api/v1/query?query=$q" | python3 -c '
import json,sys
try:
    b=json.load(sys.stdin)
except Exception as e:
    print("ERR"); sys.exit(0)
if b.get("status")!="success":
    print("ERR"); sys.exit(0)
print(len((b.get("data") or {}).get("result") or []))
' || echo ERR)
    if [ "$n" = "0" ]; then
      echo "  $title → NO DATA"
    elif [ "$n" = "ERR" ]; then
      echo "  $title → ERR"
    else
      echo "  $title → $n series"
    fi
  done < <(curl -s -u "admin:$PW" --cacert "$CA" "$G/api/dashboards/uid/$uid" | python3 -c '
import json,sys
r=json.load(sys.stdin)
d=r.get("dashboard") or {}
if not d:
    sys.exit(0)

def walk(ps):
    for p in ps:
        yield p
        if p.get("panels"):
            yield from walk(p["panels"])

for p in walk(d.get("panels") or []):
    if p.get("type") in ("text","row"):
        continue
    ts=p.get("targets") or []
    expr=(ts[0].get("expr") if ts else None) or ""
    title=(p.get("title") or p.get("type") or "?").replace("\t"," ").replace("\n"," ")
    print("%s\t%s" % (title, expr))
')
done
