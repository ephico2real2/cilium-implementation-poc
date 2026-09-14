#!/usr/bin/env bash
# lab-apps.sh — the sample applications demos 26–35 work on, deployed the way their READMEs deploy them, then exercised
# once so Hubble, the metrics, Loki and the verdicts dashboard have flows to show (enhancement 004, phase 2). Each lab is
# its own namespace and its own chapter; the policies the demos generate are NOT applied here — generating and applying
# them is the demo. What is applied: the workloads, the default-deny where the chapter starts from one (audit mode on,
# as the chapters do, so the traffic is reported and not blocked), and one round of the chapter's traffic.
#
#   scripts/lab-apps.sh all                    # every lab below, in order
#   scripts/lab-apps.sh lab26 lab30 …          # one or more
#
#   lab      namespace(s)                 demo  what runs                                               traffic
#   lab26    cf2cnp-lab                   26    shop (nginx), pos, stranger; default-deny under audit    pos → shop, stranger → shop, pos → the world
#   lab27    cf2cnp-lab27                 27    shop-frontend, shop-backend, pos, stranger               pos → frontend → backend, the stranger
#   lab30    cf2cnp-lab30                 30    the same shop with real paths, HTTP visibility           calls.sh: eight method+path cases
#   lab32    cf2cnp-lab27 (+ kiosk)       32    a new caller of demo 27's storefront                     kiosk → frontend
#   lab35    shop-edge/core/payments/     35    the platform: a gateway, a shared catalog, three teams,  probe.sh: the shopper, a team call, the stranger
#            merchant/reviews/clients           a client namespace; default-deny under audit
#   app02    default                      02    the Star Wars app behind demo 05's Gateway, with its L3/L4  the landing request (200) and the exhaust
#                                              and L7 policies — the first policy demo's end state         port (403 from the proxy)
#   bank     bank (both clusters)         15,   the bank: postgres + accounts + payments on poc2, redis +   exercise.sh through the Gateway; demo 19's
#                                        19    payments + api + web on poc1, its routes; demo 19's cell     egress-test.sh: the DROPPED flows the
#                                              (rendered policies) in both clusters                         observer, Loki and the verdict tiles show
#   dns      cf2cnp-lab                   31    the chapter's generated DNS-visibility policy on pos, so    pos → example.com / cilium.io by name
#                                              Hubble sees names (the DNS dashboard, toFQDNs later)
#   traffic  every lab above              —     `traffic <minutes>`: every generator above, round after   what a dashboard needs: minutes of it
#                                              round, then a wait until Prometheus and Loki hold it
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; PEER_CTX="${LAB_STACK_PEER_CTX:-kind-poc2}"
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }
k() { kubectl --context "$CTX" "$@"; }
ready() { k -n "$1" wait --for=condition=Ready pod --all --timeout=3m >/dev/null || { k -n "$1" get pods; die "pods in $1 did not become Ready"; }; }
hit() { # <ns> <pod> <container|-> <url> — one request, the status line the caller saw (a caller with no rule gets rc=1)
  local c=(); [ "$3" != "-" ] && c=(-c "$3")
  printf '  %-12s %-52s %s\n' "$2" "${4#http://}" "$(k -n "$1" exec "$2" "${c[@]}" -- sh -c "wget -S -qO- --timeout=3 '$4' 2>&1 | grep -m1 'HTTP/'; echo rc=\$?" 2>/dev/null | tr '\n' ' ')"
}

lab26() {
  say "demo 26 — cf2cnp-lab: shop, pos, stranger; the default-deny under audit mode; one round of traffic"
  k apply -f demos/26-cf2cnp-policy-from-flows/10-lab.yaml >/dev/null; ready cf2cnp-lab
  demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Enabled | tail -1
  k apply -f demos/26-cf2cnp-policy-from-flows/20-shop-default-deny-ingress.yaml >/dev/null
  hit cf2cnp-lab pos - http://shop.cf2cnp-lab/
  hit cf2cnp-lab stranger - http://shop.cf2cnp-lab/
  hit cf2cnp-lab pos - http://example.com/
}
lab27() {
  say "demo 27 — cf2cnp-lab27: the two-component shop, pos and the stranger; the default-deny (the release chapter enforces later)"
  k apply -f demos/27-cf2cnp-release/10-lab.yaml >/dev/null; ready cf2cnp-lab27
  k apply -f demos/27-cf2cnp-release/20-shop-default-deny-ingress.yaml >/dev/null
  hit cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/
  hit cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/
}
lab30() {
  say "demo 30 — cf2cnp-lab30: the shop with real paths and HTTP visibility; the eight calls of calls.sh"
  k apply -f demos/30-l7-rules/10-lab.yaml -f demos/30-l7-rules/20-http-visibility.yaml >/dev/null; ready cf2cnp-lab30
  demos/30-l7-rules/calls.sh 2>&1 | sed 's/^/  /'
}
lab32() {
  say "demo 32 — the kiosk, a new caller of demo 27's storefront"
  k apply -f demos/32-operator-loop/10-kiosk.yaml >/dev/null; ready cf2cnp-lab27
  hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/
}
lab35() {
  say "demo 35 — the shop platform: six namespaces; audit mode on every workload; the default-deny; probe.sh"
  k apply -f demos/35-shop-platform/10-platform.yaml >/dev/null
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews shop-clients; do ready "$ns"; done
  demos/35-shop-platform/audit-all.sh Enabled 2>&1 | tail -2 | sed 's/^/  /'
  k apply -f demos/35-shop-platform/20-default-deny-ingress.yaml >/dev/null
  demos/35-shop-platform/probe.sh 2>&1 | sed 's/^/  /'
}

app02() {
  say "demo 02 — the Star Wars app in default, behind demo 05's Gateway; its L3/L4 and L7 policies (the demo's end state)"
  k apply -f demos/02-l7-policy/http-sw-app.yaml >/dev/null; ready default
  k apply -f demos/02-l7-policy/01-l3-l4-policy.yaml -f demos/02-l7-policy/02-l7-policy.yaml >/dev/null
  sw_traffic
}
sw_traffic() { # the two requests the demo makes: allowed by L7, denied by L7 (a 403 from the proxy), and the xwing dropped at L3
  printf '  %-12s %-52s %s\n' tiefighter 'POST deathstar/v1/request-landing' "$(k exec tiefighter -- curl -s -m 3 -XPOST deathstar.default.svc.cluster.local/v1/request-landing 2>/dev/null | tr -d '\n' | cut -c1-40)"
  printf '  %-12s %-52s %s\n' tiefighter 'PUT  deathstar/v1/exhaust-port' "$(k exec tiefighter -- curl -s -m 3 -XPUT -o /dev/null -w '%{http_code}' deathstar.default.svc.cluster.local/v1/exhaust-port 2>/dev/null)"
  printf '  %-12s %-52s %s\n' xwing 'POST deathstar/v1/request-landing' "$(k exec xwing -- curl -s -m 3 -o /dev/null -w '%{http_code}' -XPOST deathstar.default.svc.cluster.local/v1/request-landing 2>/dev/null || echo 'no answer (dropped at L3)')"
}
bank() {
  say "demos 15 + 19 — the bank in both clusters, its routes, and the zero-trust cell's rendered policies"
  # bankdemo:local is the lab's own image: scripts/lab-images.sh builds it and loads it into every cluster BEFORE the labs
  # (a node cannot pull what exists only in the host's Docker — run 34903231161); here it is only checked
  for c in "$CTX" "$PEER_CTX"; do docker exec "${c#kind-}-control-plane" crictl images 2>/dev/null | grep -q 'bankdemo' || die "bankdemo:local is not in ${c#kind-}'s nodes — scripts/lab-images.sh first"; done
  kubectl --context "$PEER_CTX" apply -f demos/15-bank/10-poc2.yaml >/dev/null; sleep 2; kubectl --context "$PEER_CTX" apply -f demos/15-bank/10-poc2.yaml >/dev/null   # the SA race the guide names
  kubectl --context "$PEER_CTX" -n bank rollout status sts/postgres --timeout=5m >/dev/null; kubectl --context "$PEER_CTX" -n bank rollout status deploy/accounts deploy/payments --timeout=5m >/dev/null
  k apply -f demos/15-bank/20-poc1.yaml >/dev/null; sleep 2; k apply -f demos/15-bank/20-poc1.yaml >/dev/null
  k -n bank rollout status sts/redis deploy/payments deploy/api deploy/web --timeout=5m >/dev/null
  k apply -f demos/15-bank/30-gateway.yaml >/dev/null
  for c in "$CTX" "$PEER_CTX"; do kubectl --context "$c" apply -f demos/19-zero-trust-cell/10-platform-baseline.yaml -f demos/19-zero-trust-cell/rendered/cell-policies.yaml >/dev/null; done
  echo "bank up in both clusters; $(k -n bank get cnp --no-headers | wc -l | tr -d ' ') cell policies in poc1, $(kubectl --context "$PEER_CTX" -n bank get cnp --no-headers | wc -l | tr -d ' ') in poc2"
  bank_traffic
}
bank_traffic() { # demo 15's payments through the Gateway (CA: this lab's root, exported by lab-stack.sh), demo 19's egress probe (the drops)
  CA="${ROOT_CA:-.tmp/root-ca.crt}" demos/15-bank/exercise.sh 5 chk-1001 2>&1 | tail -3 | sed 's/^/  /' || true
  demos/19-zero-trust-cell/egress-test.sh "${CTX#kind-}" 2>&1 | tail -4 | sed 's/^/  /' || true
}
dns() {
  say "demo 31 — the chapter's generated DNS-visibility policy on cf2cnp-lab/pos (names in Hubble's flows and the DNS dashboard)"
  k apply -f demos/31-dns-visibility/policies/cnp-pos-dns-visibility.yaml >/dev/null
  hit cf2cnp-lab pos - http://example.com/; hit cf2cnp-lab pos - https://cilium.io/
}
traffic() { # <minutes> — every generator, round after round, then the wait for the metrics that the dashboards read
  local minutes="${1:-5}" end round=0; end=$(( $(date +%s) + minutes * 60 ))
  say "traffic for $minutes minutes — every lab's generators, round after round (a dashboard's rate windows need minutes, not a burst)"
  while [ "$(date +%s)" -lt "$end" ]; do
    round=$((round + 1))
    { hit cf2cnp-lab pos - http://shop.cf2cnp-lab/; hit cf2cnp-lab stranger - http://shop.cf2cnp-lab/; hit cf2cnp-lab pos - http://example.com/
      hit cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/; hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/
      demos/30-l7-rules/calls.sh; demos/35-shop-platform/probe.sh
      k get pod tiefighter >/dev/null 2>&1 && sw_traffic
      k -n bank get deploy api >/dev/null 2>&1 && bank_traffic
    } >/dev/null 2>&1 || true
    printf '  round %d at %s\n' "$round" "$(date +%H:%M:%S)"; sleep 15
  done
  say "waiting until Prometheus and Loki hold what the dashboards read"
  local q _i n
  for q in 'sum(rate(hubble_http_requests_total[5m]))' 'sum(hubble_dns_queries_total)' 'sum(hubble_policy_verdicts_total{action="dropped"})' 'sum(hubble_flows_processed_total)'; do
    for _i in $(seq 1 30); do
      n=$(k get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$q")" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")' 2>/dev/null || true)
      [ -n "$n" ] && [ "$n" != "0" ] && break; sleep 10
    done
    printf '  %-56s %s\n' "$q" "${n:-nothing after 5 min}"
  done
  n=$(k get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query?query=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("sum(count_over_time({namespace=\"hubble-observer\",container=\"hubble-observer\"}[15m]))"))')" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "0")' 2>/dev/null || echo "?")
  printf '  %-56s %s\n' "Loki: observer lines, last 15 min" "$n"
}

[ $# -ge 1 ] || { echo "usage: $0 all | lab26 lab27 lab30 lab32 lab35 app02 bank dns | traffic <minutes>"; exit 2; }
[ "$1" = all ] && set -- lab26 lab27 lab30 lab32 lab35 app02 bank dns
while [ $# -gt 0 ]; do
  case "$1" in
    lab26|lab27|lab30|lab32|lab35|app02|bank|dns) "$1"; shift;;
    traffic) traffic "${2:-5}"; shift 2;;
    *) die "unknown lab $1";;
  esac
done
say "labs on ${CTX#kind-}: done"
