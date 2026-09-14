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
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"
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

[ $# -ge 1 ] || { echo "usage: $0 all | lab26 lab27 lab30 lab32 lab35"; exit 2; }
[ "$1" = all ] && set -- lab26 lab27 lab30 lab32 lab35
for l in "$@"; do case "$l" in lab26|lab27|lab30|lab32|lab35) "$l";; *) die "unknown lab $l";; esac; done
say "labs up on ${CTX#kind-}: $*"
