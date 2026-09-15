#!/usr/bin/env bash
# lab-report.sh [out.md] — the demos' OWN checks, run after the traffic, as one report: a heading, the command as the
# guide prints it, its output. The workflow appends it to the run page (the job summary) above the captures and keeps it
# in the artifact, so the page says what was installed, what was exercised and what each chapter's check saw — the
# "testing" a reader looks for (the operator, 2026-09-15). The checks are the demos' evidence printers: they exit 0 by
# design, so the table at the top counts their lines and the words that mean trouble; the pipeline's pass/fail stays
# with the steps that can fail (rollouts, the wait for the metrics).
#
#   demo  check                                            proves
#   16    Prometheus: targets up, the Hubble metric families the dashboards read, with samples
#   25    demos/25-hubble-observer-loki/check.sh            observer → collector → Loki → Grafana → cf2cnp, sent_logs > 0 after the drops
#   18    demos/18-obi/check.sh                             the requests OBI saw, with their trace ids, both clusters
#   23    demos/23-collector-per-cluster/check.sh           the collector's local-only backends, its Tempo exporter counters, traces per cluster in Tempo
#   19    demos/19-zero-trust-cell/drops.sh                 what Hubble DENIED in the bank namespace, with the policy that denied it
#   26    demos/26-cf2cnp-policy-from-flows/verify.sh       the lab's verdicts per (source → destination:port) with the policy
#   30    demos/30-l7-rules/l7-summary.sh                   the method+path pairs from the proxy's flows
#   35    demos/35-shop-platform/verdicts.sh                the platform's audited pairs
#   (15   demos/15-bank/check.sh needs demo 11's forensic client pod — the bank is exercised through the Gateway in the traffic step instead)
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1
OUT="${1:-captures/report.md}"; mkdir -p "$(dirname "$OUT")"; CTX="${LAB_STACK_CTX:-kind-poc1}"; export ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}"
k() { kubectl --context "$CTX" "$@"; }
declare -a NAMES LINES FLAGS
section() { # <name> <command…> — run, capture, append
  local name="$1"; shift; local out
  out=$("$@" 2>&1 | head -80) || true
  NAMES+=("$name"); LINES+=("$(printf '%s\n' "$out" | grep -c . )"); FLAGS+=("$(printf '%s\n' "$out" | grep -ciE 'fail|✗|error|not found|timed out' || true)")
  { echo; echo "### $name"; echo; echo '```'; echo "\$ $*"; printf '%s\n' "$out"; echo '```'; } >> "$OUT.body"
}
prom() { k get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")' 2>/dev/null || echo "?"; }
demo16() {
  echo "targets up: $(k get --raw '/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/targets?state=active' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["activeTargets"]; print(sum(1 for t in d if t["health"]=="up"), "of", len(d))')"
  for m in hubble_flows_processed_total hubble_http_requests_total hubble_dns_queries_total hubble_policy_verdicts_total hubble_drop_total cilium_endpoint_state cilium_policy_change_total; do printf '  %-32s %s\n' "$m" "$(prom "sum($m)")"; done
  printf '  %-32s %s\n' "grafana dashboards provisioned" "$(k get cm -A -l grafana_dashboard=1 --no-headers | wc -l | tr -d ' ')"
}
rm -f "$OUT.body"
section "demo 16 — Prometheus, the metric families the dashboards read" demo16
section "demo 25 — the observer pipeline (demos/25-hubble-observer-loki/check.sh 1)" demos/25-hubble-observer-loki/check.sh 1
section "demo 18 — OBI, the requests it saw with their trace ids (demos/18-obi/check.sh 20m)" demos/18-obi/check.sh 20m
section "demo 23 — the collector per cluster and Tempo's traces per cluster (demos/23-collector-per-cluster/check.sh 20)" demos/23-collector-per-cluster/check.sh 20
section "demo 19 — what Hubble denied in bank, both clusters, with the policy (demos/19-zero-trust-cell/drops.sh 20m)" demos/19-zero-trust-cell/drops.sh 20m
section "demo 26 — the lab's verdicts with the deciding policy (demos/26-cf2cnp-policy-from-flows/verify.sh 20m)" demos/26-cf2cnp-policy-from-flows/verify.sh 20m
section "demo 30 — method+path pairs from the proxy's flows (demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300)" demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300
section "demo 35 — the platform's audited pairs (demos/35-shop-platform/verdicts.sh 300)" demos/35-shop-platform/verdicts.sh 300
{
  echo "## The demos' checks, after ${TRAFFIC_MINUTES:-?} minutes of traffic"
  echo; echo "| check | lines | words that mean trouble |"; echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do echo "| ${NAMES[$i]%% (*} | ${LINES[$i]} | ${FLAGS[$i]} |"; done
  cat "$OUT.body"
} > "$OUT"; rm -f "$OUT.body"
echo "report: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"; grep -E '^\| ' "$OUT"
