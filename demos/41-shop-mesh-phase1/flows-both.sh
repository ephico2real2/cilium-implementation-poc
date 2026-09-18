#!/usr/bin/env bash
# flows-both.sh [last] — AUDIT INGRESS request flows into every shop service namespace, per cluster,
# saved under policies/<cluster>/flows-audit.ndjson. Demo 35's audit-flows.sh, generalised.
#
#   demos/41-shop-mesh-phase1/flows-both.sh
#   CONTEXTS="kind-poc1" LAST=400 demos/41-shop-mesh-phase1/flows-both.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
LAST="${1:-${LAST:-400}}"
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)
HERE=demos/41-shop-mesh-phase1
mkdir -p "$HERE/policies"

summarise() {
  python3 - "$1" <<'PY'
import json,sys,collections
c=collections.OrderedDict(); n=0
def who(e):
    w=(e.get("workloads") or [{"name": e.get("pod_name","?")}])[0]
    return w.get("name","?")+"@"+e.get("namespace","?")
def cl(e):
    return e.get("cluster_name") or "-"
try:
    fh=open(sys.argv[1])
except OSError as e:
    print("0 AUDIT INGRESS request flows ->", sys.argv[1], f"({e})")
    sys.exit(0)
for l in fh:
    try: f=json.loads(l)["flow"]
    except Exception: continue
    if f.get("is_reply") or f.get("traffic_direction")!="INGRESS": continue
    s,d=f["source"],f["destination"]
    l4=f.get("l4",{}); port=(l4.get("TCP") or {}).get("destination_port")
    k=(who(s), cl(s), who(d), cl(d), port); c[k]=c.get(k,0)+1; n+=1
print(n, "AUDIT INGRESS request flows ->", sys.argv[1])
for (s,sc,d,dc,p),m in sorted(c.items(), key=lambda kv: (kv[0][2], kv[0][0])):
    extra=""
    if sc != dc and sc not in ("-","") and dc not in ("-",""):
        extra=f"  (src.cluster={sc} dst.cluster={dc})"
    print("  {:3}  {:28} -> {}:{}{}".format(m, s, d, p, extra))
PY
}

rc=0
for ctx in "${CTX_ARR[@]}"; do
  c=${ctx#kind-}
  out="$HERE/policies/$c/flows-audit.ndjson"
  mkdir -p "$(dirname "$out")"
  : > "$out"
  echo "== $ctx → $out"
  captured=0
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
    err=$(mktemp)
    if hubble observe -P --kube-context "$ctx" --to-namespace "$ns" --verdict AUDIT --last "$LAST" -o json >> "$out" 2>"$err"; then
      captured=1
    else
      echo "  hubble observe --kube-context $ctx --to-namespace $ns failed:" >&2
      cat "$err" >&2 || true
      rc=1
    fi
    rm -f "$err"
  done
  summarise "$out"
  n=$(wc -l < "$out" | tr -d ' ')
  if [ "${n:-0}" -eq 0 ]; then
    echo "MEASURED GAP: no AUDIT flows captured on $ctx (hubble observe failed or returned nothing)."
    [ "$captured" -eq 0 ] && rc=1
  fi
done
exit "$rc"
