#!/usr/bin/env bash
# provision.sh — put the six tutorial dashboards on the lab's Grafana (Tutorial folder) via the sidecar, then wait
# until each uid answers 200 and print what the API stored (uid, title, panel count).
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }
CA="${ROOT_CA:-.tmp/root-ca.crt}"
PW=$(k -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
DIR=demos/38-grafana-visual-grammar/dashboards

uids=()
for f in "$DIR"/tut-*.json; do
  base=$(basename "$f" .json)
  uids+=("$base")
  echo "  apply $base"
  demos/25-hubble-observer-loki/dashboard-from-file.sh "$f" monitoring "grafana-${base}" "$base" Tutorial | k apply -f - || echo "  apply failed: $f"
done

ok=0
for i in $(seq 1 90); do
  ok=1
  for uid in "${uids[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" --cacert "$CA" "https://grafana.poc.local/api/dashboards/uid/$uid" || true)
    [ "$code" = 200 ] || ok=0
  done
  [ "$ok" -eq 1 ] && break
  sleep 1
done
[ "$ok" -eq 1 ] || echo "  wait: not all uids returned 200 within 90s"

echo "== provisioned"
for uid in "${uids[@]}"; do
  curl -s -u "admin:$PW" --cacert "$CA" "https://grafana.poc.local/api/dashboards/uid/$uid" | python3 -c '
import json,sys
r=json.load(sys.stdin)
d=r.get("dashboard") or {}
print("  uid=%s title=%s panels=%s" % (d.get("uid","?"), d.get("title","?"), len(d.get("panels") or [])))
' || echo "  uid=$uid title=? panels=?  (API read failed)"
done
