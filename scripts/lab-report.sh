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
#   36    demos/36-trust-everywhere/check.sh                one root everywhere: the chain (which CA signed the wildcard), the host's trust store and
#                                                           a curl by name with no --cacert, trust-manager's Bundle in both clusters, a pod's curl
#                                                           with the mounted root (answered) and without (refused)
#   15    demos/15-bank/check.sh                            the bank ACROSS the mesh from inside (demo 11's forensic client): the merged service
#                                                           maps, a payment's hops, active-active, two failovers, the page through the Gateway —
#                                                           run by lab-apps.sh BEFORE demo 19's cell (the cell denies the forensic namespace),
#                                                           its saved output shown here
#   20    demos/20-springboot/check.sh                      the petclinic's API through the Gateway: owners, pets, vets, a visit, a POST
#   19    demos/19-zero-trust-cell/drops.sh                 what Hubble DENIED in the bank namespace, with the policy that denied it
#   —     the generated policies                            every CiliumNetworkPolicy cf2cnp generated in the chapters, Valid as the agent sees it
#   26    demos/26-cf2cnp-policy-from-flows/verify.sh       the lab's verdicts per (source → destination:port) with the policy
#   30    demos/30-l7-rules/l7-summary.sh                   the method+path pairs from the proxy's flows (403s once enforced)
#   35    demos/35-shop-platform/verdicts.sh                the platform's pairs with the deciding policy
# A check whose prerequisite is absent (no forensic client, no petclinic) is listed as skipped, not run. Every check runs
# under a deadline (SECTION_TIMEOUT, 10 min) where `timeout` exists: one check that hangs must not eat the job (run
# 34922062949 sat 94 minutes on curls that never got a SYN-ACK).
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1
OUT="${1:-captures/report.md}"; mkdir -p "$(dirname "$OUT")"; CTX="${LAB_STACK_CTX:-kind-poc1}"; export ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}"
k() { kubectl --context "$CTX" "$@"; }
declare -a NAMES LINES FLAGS
section() { # <name> <command…> — run (under the deadline), capture, append
  local name="$1"; shift; local out
  # `timeout` runs programs, not this shell's functions (run 34930321170: "failed to run command 'demo16'"): a function
  # runs as it is — the two here are a handful of kubectl calls — and a script runs under the deadline
  if declare -F "$1" >/dev/null 2>&1 || ! command -v timeout >/dev/null; then out=$("$@" 2>&1 | head -${SECTION_LINES:-80}) || true
  else out=$(timeout "${SECTION_TIMEOUT:-10m}" "$@" 2>&1 | head -${SECTION_LINES:-80}) || true; fi
  # the words that mean trouble — `failed=0` and `fail=0` are counters at rest, not trouble (run 34918170151's table said 2 and 7)
  NAMES+=("$name"); LINES+=("$(printf '%s\n' "$out" | grep -c . )"); FLAGS+=("$(printf '%s\n' "$out" | grep -ciE '✗|error|not found|timed out|fail(ed|ure)?([^=a-z]|$)|fail(ed)?=[1-9]' || true)")
  { echo; echo "### $name"; echo; echo '```'; echo "\$ $*"; printf '%s\n' "$out"; echo '```'; } >> "$OUT.body"
}
skipped() { NAMES+=("$1"); LINES+=("skipped"); FLAGS+=("—"); { echo; echo "### $1"; echo; echo "_skipped: $2_"; } >> "$OUT.body"; }
policies() { # every generated policy the chapters applied, with the agent's Valid condition (gotcha #80) and its description
  local d="${LAB_POLICIES_DIR:-captures/policies}" f
  find "$d" -name '*.yaml' 2>/dev/null | sort | while read -r f; do
    k create --dry-run=client -o json -f "$f" 2>/dev/null | jq -r --arg f "$f" 'if .kind == "List" then .items[] else . end | select(.kind == "CiliumNetworkPolicy") | "\(.metadata.namespace)/\(.metadata.name)\t\($f)"'   # a stream or a List (gotcha #106)
  done | sort -u | while IFS=$'\t' read -r n f; do
    printf '  %-34s Valid=%-5s %-46s %s\n' "$n" "$(k -n "${n%%/*}" get cnp "${n##*/}" -o jsonpath='{.status.conditions[?(@.type=="Valid")].status}' 2>/dev/null || echo '?')" "$f" "$(k -n "${n%%/*}" get cnp "${n##*/}" -o jsonpath='{.spec.description}' 2>/dev/null | cut -c1-90)"
  done
  echo "  files: $(find "$d" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ') generated, $(find "$d" -name '*.ndjson' -o -name '*.json' 2>/dev/null | wc -l | tr -d ' ') flow captures under $d"
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
section "demo 36 — one root, everywhere: the chain, the host, both clusters' Bundles, a pod (demos/36-trust-everywhere/check.sh)" demos/36-trust-everywhere/check.sh
if [ -s "${LAB_CHECKS_DIR:-captures/checks}/demo15-check.txt" ]; then SECTION_LINES=120 section "demo 15 — the bank across the mesh, from inside, with two failovers (demos/15-bank/check.sh, run before the cell by lab-apps.sh)" cat "${LAB_CHECKS_DIR:-captures/checks}/demo15-check.txt"
else skipped "demo 15 — the bank across the mesh, from inside (demos/15-bank/check.sh)" "no saved output: the bank lab did not run with demo 11's forensic client (scripts/lab-apps.sh forensic bank)"; fi
if k -n springboot get deploy api-gateway >/dev/null 2>&1; then section "demo 20 — the petclinic's API through the Gateway (demos/20-springboot/check.sh 5)" demos/20-springboot/check.sh 5
else skipped "demo 20 — the petclinic's API through the Gateway (demos/20-springboot/check.sh 5)" "the petclinic is not deployed (scripts/lab-apps.sh springboot)"; fi
section "demo 19 — what Hubble denied in bank, both clusters, with the policy (demos/19-zero-trust-cell/drops.sh 20m)" demos/19-zero-trust-cell/drops.sh 20m
section "the generated policies — every CiliumNetworkPolicy cf2cnp wrote in the chapters, as the agent sees it" policies
section "demo 26 — the lab's verdicts with the deciding policy (demos/26-cf2cnp-policy-from-flows/verify.sh 20m)" demos/26-cf2cnp-policy-from-flows/verify.sh 20m
section "demo 30 — method+path pairs from the proxy's flows (demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300)" demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300
section "demo 35 — the platform's pairs with the deciding policy (demos/35-shop-platform/verdicts.sh 300)" demos/35-shop-platform/verdicts.sh 300
{
  echo "## The demos' checks, after ${TRAFFIC_MINUTES:-?} minutes of traffic"
  echo; echo "| check | lines | words that mean trouble |"; echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do echo "| ${NAMES[$i]%% (*} | ${LINES[$i]} | ${FLAGS[$i]} |"; done
  cat "$OUT.body"
} > "$OUT"; rm -f "$OUT.body"
echo "report: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"; grep -E '^\| ' "$OUT"
