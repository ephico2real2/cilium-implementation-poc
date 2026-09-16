#!/usr/bin/env bash
# lab-all.sh — everything after lab-up.sh, in the Action's order, on a laptop: the same scripts lab-observability.yaml runs
# step by step, with the two traffic windows as parameters instead of the runner's fixed minutes (the operator,
# 2026-09-15: "we don't need the crazy wait time … make the wait time parameterizable such that we can pass what we want").
#
#   scripts/lab-all.sh                                        # deploy everything, one minute of traffic, the policies, the checks — no long waits
#   LAB_AUDIT_MINUTES=3 LAB_TRAFFIC_MINUTES=6 scripts/lab-all.sh   # the Action's windows (run 35028933940's inputs)
#   LAB_CAPTURE=1 scripts/lab-all.sh                          # + the pages walked with their expectations (Playwright into .tmp/pw)
#   LAB_SKIP="images stack" scripts/lab-all.sh                # skip steps already done (every step is idempotent anyway)
#
#   step        what runs                                                     the Action's step
#   gateway     demo 05's Gateway from the pool, demo 07's global service,     "A Gateway with an address from the pool …"
#               scripts/lab-route.sh, every LoadBalancer address answered
#   images      scripts/lab-images.sh poc1 poc2                              "The lab's images — built, loaded into every cluster"
#   stack       scripts/lab-stack.sh routes monitoring tempo collectors       "The observability stack — demos 09, 16, 21, 10/22/23, 25, 18 …"
#               loki-observer [obi] hubble-cli kyverno                        (LAB_OBI=0 leaves demo 18 out, the heaviest stack)
#   apps        scripts/lab-apps.sh all — every lab, exercised once           "The labs of demos 26, 27, 30, 32, 35, …"
#   audit       scripts/lab-apps.sh rounds $LAB_AUDIT_MINUTES                 "Traffic under audit for N minutes" — CI: 3; here: 1
#   policies    scripts/lab-policies.sh all — flows → policies → applied      "The cf2cnp chapters …"
#   traffic     scripts/lab-apps.sh traffic $LAB_TRAFFIC_MINUTES              "Traffic once enforced, N minutes, then the wait …" — CI: 6;
#               (rounds, then the strict wait for Prometheus, Loki and Tempo)  here: 0 = skipped
#   report      scripts/lab-report.sh captures/report.md                      "The report — the demos' checks"
#   capture     scripts/lab-capture.sh (LAB_CAPTURE=1)                        "Captures — Grafana's dashboards, the Hubble UI, cf2cnp …"
#
# What the windows are for, so the defaults are a decision and not a guess: `rounds` feeds the dashboards' 5-minute rate
# panels, and `traffic` ends in the wait that makes "the dashboards have data" a test on the runner. The policies need
# only flows that exist — `lab-apps.sh all` already exercises every lab once — so one minute of rounds is the laptop's
# audit window (fresh flows right before the chapters read them) and the enforced-traffic wait is skipped. The
# expectations behind LAB_CAPTURE=1 are the runner's (every panel has data); with short windows some rate panels will
# say "No data", and the walk reports that as a failed page — which is the true state, not a bug.
#
# Each step's outcome is recorded (.tmp/failed-steps) and the run continues, as the Action does; the verdict is last.
# Two things a Mac does not do from a shell that cannot prompt: the System keychain (scripts/lab-trust.sh install) and
# the host route's sudo (scripts/lab-route.sh warns and goes on) — run them once in a Terminal (docs/NEW-MAC.md §4).
set -uo pipefail; cd "$(dirname "$0")/.."
LAB_AUDIT_MINUTES="${LAB_AUDIT_MINUTES:-1}"; LAB_TRAFFIC_MINUTES="${LAB_TRAFFIC_MINUTES:-0}"
LAB_CAPTURE="${LAB_CAPTURE:-0}"; LAB_OBI="${LAB_OBI:-1}"; LAB_SKIP="${LAB_SKIP:-}"
CTX="${LAB_STACK_CTX:-kind-poc1}"; PEER="${LAB_PEER_CTX:-kind-poc2}"
export ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}"        # the checks' trust anchor; lab-up.sh wrote it (a host that trusts the root works too)
mkdir -p .tmp captures; : > .tmp/failed-steps; T0=$(date +%s)
say() { printf '\n== %s  (%s)\n' "$*" "$(date +%H:%M:%S)"; }
fail() { echo "$1" >> .tmp/failed-steps; echo "::error::$1"; }
skip() { case " $LAB_SKIP " in *" $1 "*) echo "  (LAB_SKIP: $1)"; return 0;; esac; return 1; }
for t in kubectl jq curl; do command -v "$t" >/dev/null || { echo "$t is not installed" >&2; exit 1; }; done
kubectl --context "$CTX" get nodes >/dev/null 2>&1 || { echo "no cluster at context $CTX — scripts/lab-up.sh poc1 poc2 first" >&2; exit 1; }
echo "lab-all: audit ${LAB_AUDIT_MINUTES} min, enforced traffic ${LAB_TRAFFIC_MINUTES} min, capture ${LAB_CAPTURE}, obi ${LAB_OBI}${LAB_SKIP:+, skipping: $LAB_SKIP}"

say "gateway — demo 05's Gateway from the pool, demo 07's global service, the host route, every LoadBalancer address"
if ! skip gateway; then
  kubectl --context "$CTX" apply -f demos/05-gateway-api/gateway.yaml
  a=""; for _ in $(seq 1 30); do a=$(kubectl --context "$CTX" get gateway -A -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null); [ -n "$a" ] && break; sleep 5; done
  echo "gateway address: ${a:-NONE}"; kubectl --context "$CTX" get gateway -A
  if [ -n "$a" ]; then
    for c in "$CTX" "$PEER"; do kubectl --context "$c" apply -f demos/07-clustermesh/global-service.yaml; done
    kubectl --context "$CTX" apply -f demos/07-clustermesh/backend-poc1.yaml; kubectl --context "$PEER" apply -f demos/07-clustermesh/backend-poc2.yaml
    kubectl --context "$CTX" rollout status deploy/rebel-base --timeout=5m; kubectl --context "$PEER" rollout status deploy/rebel-base --timeout=5m
    scripts/lab-route.sh "$CTX"
    kubectl --context "$PEER" get svc rebel-base-lb >/dev/null 2>&1 || kubectl --context "$PEER" expose deploy rebel-base --name rebel-base-lb --type LoadBalancer --port 80 --target-port 80
    # every LoadBalancer address, answered over HTTP from this host (the runner adds the ARP neighbour; a Mac's next hop is
    # the VM, so the host never ARPs for a pool address — docs/DOCKER-DESKTOP-RUNBOOK.md)
    for c in "$CTX" "$PEER"; do
      echo "== $c: its pools, and every LoadBalancer address it holds"
      kubectl --context "$c" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,START:.spec.blocks[*].start,STOP:.spec.blocks[*].stop,CONFLICT:.status.conditions[?(@.type=="cilium.io/PoolConflict")].status' --no-headers
      for _ in $(seq 1 24); do pending=$(kubectl --context "$c" get svc -A -o json | jq '[.items[] | select(.spec.type=="LoadBalancer") | select((.status.loadBalancer.ingress // []) | length == 0)] | length'); [ "$pending" = 0 ] && break; sleep 5; done
      kubectl --context "$c" get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name) \(.status.loadBalancer.ingress[0].ip // "<pending>")"' | while read -r svc ip; do
        printf '  %-34s %-16s ' "$svc" "$ip"
        case "$ip" in \<pending\>) echo "NO ADDRESS"; continue;; esac
        code=$(curl -s -o /dev/null -m 8 --connect-timeout 3 -w '%{http_code}' "http://$ip/" || true); echo "HTTP ${code:-000}"
      done
    done
  else fail "the Gateway got no address from the pool"; fi
fi

say "images — built here, loaded into every cluster"
skip images || scripts/lab-images.sh poc1 poc2 || fail "the images (scripts/lab-images.sh)"

say "stack — demos 09, 16, 21, 10/22/23, 25, 18, the CLI's certificate, demo 36's Kyverno"
if ! skip stack; then
  steps="routes monitoring tempo collectors loki-observer"; [ "$LAB_OBI" = 1 ] && steps="$steps obi"; steps="$steps hubble-cli kyverno"
  scripts/lab-stack.sh $steps || fail "the stack (scripts/lab-stack.sh)"
  echo "== what it costs with the stacks up"; docker stats --no-stream --format '  {{.Name}} {{.CPUPerc}} {{.MemUsage}}' 2>/dev/null || true
fi

say "apps — the labs of demos 26, 27, 30, 32, 35, the Star Wars app, the bank and the cell, the DNS policy, the forensic client, the petclinic, the labelled client"
skip apps || scripts/lab-apps.sh all || fail "the labs (scripts/lab-apps.sh all)"

say "audit — traffic under audit for $LAB_AUDIT_MINUTES minute(s): the observation the policies are generated from"
if ! skip audit; then [ "$LAB_AUDIT_MINUTES" -gt 0 ] && { scripts/lab-apps.sh rounds "$LAB_AUDIT_MINUTES" || fail "the audit traffic"; } || echo "  LAB_AUDIT_MINUTES=0: the one round lab-apps.sh all made is the observation"; fi

say "policies — the cf2cnp chapters: flows → policies, validated, applied, re-tested"
skip policies || scripts/lab-policies.sh all || fail "the cf2cnp chapters (scripts/lab-policies.sh)"

say "traffic — once enforced, $LAB_TRAFFIC_MINUTES minute(s), then the wait for the metrics, the logs and the traces"
if ! skip traffic; then [ "$LAB_TRAFFIC_MINUTES" -gt 0 ] && { scripts/lab-apps.sh traffic "$LAB_TRAFFIC_MINUTES" || fail "the wait for the metrics, the logs and the traces"; } || echo "  LAB_TRAFFIC_MINUTES=0: skipped (the runner's strict data wait; set it for the dashboards' rate windows)"; fi

say "report — the demos' checks, to captures/report.md"
skip report || { TRAFFIC_MINUTES=$(( LAB_AUDIT_MINUTES + LAB_TRAFFIC_MINUTES )) scripts/lab-report.sh captures/report.md | tail -16; scripts/lab-route.sh "$CTX" | tail -12; }   # the heading says how many minutes of traffic preceded the checks

say "capture — the pages with their expectations"
if ! skip capture; then [ "$LAB_CAPTURE" = 1 ] && { scripts/lab-capture.sh || fail "the captures (scripts/lab-capture.sh): a page missed an expectation — captures/walk.log says which"; } || echo "  LAB_CAPTURE=0: skipped (open the pages: scripts/lab-route.sh $CTX prints the addresses)"; fi

say "the verdict"
echo "total $(( ($(date +%s) - T0) / 60 )) min $(( ($(date +%s) - T0) % 60 )) s"
if [ -s .tmp/failed-steps ]; then echo "FAILED:"; sed 's/^/  /' .tmp/failed-steps; exit 1; else echo "every step passed"; fi
