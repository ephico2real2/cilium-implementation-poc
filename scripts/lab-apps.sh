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
#   dns      cf2cnp-lab                   31    the chapter's recorded toFQDNs policy on pos, so Hubble     pos → example.com (443 allowed, 80 not),
#                                              sees names (the DNS dashboard); chapter 31 regenerates it    cilium.io (not yet)
#   forensic forensic                     11    the rig's client pod (netshoot: curl, jq) — what demo 15's  none: it is a tool for the checks
#                                              in-cluster check runs from; the rig's node affinity dropped
#   springboot springboot                 20    the petclinic: six Spring Boot services, their own spans     check.sh through the Gateway: owners,
#                                              in Zipkin format to the collector; the memory measured        pets, vets, visits, a POST
#   trust    trust                        36    a client that declares no mount and no flag, only the label  from the pod: https://bank.poc.local
#                                              trust.poc.local/root=enterprise — Kyverno mounts the root     with no --cacert (SSL_CERT_FILE)
#   rounds   every lab above              —     `rounds <minutes>`: every generator above, round after round — what a dashboard's rate windows need
#   wait     —                            —     until Prometheus, Loki and Tempo (both clusters) hold what the dashboards read — or fail
#   traffic  every lab above              —     `traffic <minutes>`: rounds, then wait
set -euo pipefail; cd "$(dirname "$0")/.."
# deadline <duration> <cmd…> — GNU timeout on the runner, Homebrew coreutils' gtimeout on a Mac (scripts/bootstrap/macos.sh
# installs it); with neither the command runs unguarded and SAYS so — `command -v timeout && … || exec` used to fall
# through silently on macOS, and a hung check had no ceiling (gotcha #112)
deadline() { if command -v timeout >/dev/null; then timeout "$@"; elif command -v gtimeout >/dev/null; then gtimeout "$@"
  else echo "::warning::no timeout/gtimeout on this host — $2 runs with no $1 ceiling (brew install coreutils)" >&2; shift; "$@"; fi; }
# reset_chapter <namespace…> — a re-run (a laptop; the runner never re-runs) finds the chapter's generated policies from the
# last pass (cf2cnp labels every one app.kubernetes.io/managed-by=cf2cnp), and the lab's "under audit" start is then a lie:
# pos → shop is FORWARDED by last time's allow, never AUDIT, and chapter 26 finds no flow to generate from (the M5's third
# pass, 2026-09-15 — gotcha #112's second face). Removed here, so the lab starts where the demo starts; a first run finds none.
# The lab-owned default-deny and visibility policies carry no such label and stay. One lab-applied policy DOES carry it:
# demo 31's recorded cnp-pos-fqdn.yaml (cf2cnp wrote it), which dns() applies in cf2cnp-lab — lab26's reset removes it and
# dns() re-applies it later in `all`; run `lab26` alone after `dns` and the DNS lab needs `dns` again (review C1).
reset_chapter() { local ns; for ns in "$@"; do k -n "$ns" delete ciliumnetworkpolicies -l app.kubernetes.io/managed-by=cf2cnp --ignore-not-found >/dev/null 2>&1 || true; done; }
CTX="${LAB_STACK_CTX:-kind-poc1}"; PEER_CTX="${LAB_STACK_PEER_CTX:-kind-poc2}"
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }
k() { kubectl --context "$CTX" "$@"; }
ready() { k -n "$1" wait --for=condition=Ready pod --all --timeout=3m >/dev/null || { k -n "$1" get pods; die "pods in $1 did not become Ready"; }; }
pod_ip() { k -n "$1" get pod -l "$2" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null; }   # <ns> <label=value>
hit() { # <ns> <pod> <container|-> <url> — one request, the status line the caller saw (a caller with no rule gets rc=1)
  local c=(); [ "$3" != "-" ] && c=(-c "$3")
  printf '  %-12s %-52s %s\n' "$2" "${4#http://}" "$(k -n "$1" exec "$2" "${c[@]}" -- sh -c "wget -S -qO- --timeout=3 '$4' 2>&1 | grep -m1 'HTTP/'; echo rc=\$?" 2>/dev/null | tr '\n' ' ')"
}

lab26() {
  say "demo 26 — cf2cnp-lab: shop, pos, stranger; the default-deny under audit mode; one round of traffic"
  k apply -f demos/26-cf2cnp-policy-from-flows/10-lab.yaml >/dev/null; ready cf2cnp-lab; reset_chapter cf2cnp-lab
  demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Enabled | tail -1
  k apply -f demos/26-cf2cnp-policy-from-flows/20-shop-default-deny-ingress.yaml >/dev/null
  hit cf2cnp-lab pos - http://shop.cf2cnp-lab/
  hit cf2cnp-lab stranger - http://shop.cf2cnp-lab/
  hit cf2cnp-lab pos - http://example.com/
  # ICMP, measured once here (the rounds repeat it silently): busybox ping falls back to a datagram socket when raw is refused
  printf '  %-12s %-52s %s\n' stranger "ping shop's pod $(pod_ip cf2cnp-lab app=shop) (ICMP echo)" "$(k -n cf2cnp-lab exec stranger -- ping -c 1 -W 2 "$(pod_ip cf2cnp-lab app=shop)" 2>&1 | tail -1)"
}
lab27() {
  say "demo 27 — cf2cnp-lab27: the two-component shop, pos and the stranger; both components under audit, then the default-deny"
  k apply -f demos/27-cf2cnp-release/10-lab.yaml >/dev/null; ready cf2cnp-lab27; reset_chapter cf2cnp-lab27
  # audit mode on BOTH endpoints before the default-deny (demo 27 Exercise 1) — without it the default-deny enforces from the
  # start: no AUDIT flows to generate from, and cf2cnp-lab27 was 83% of the observer's drops in run 34918170151
  NS=cf2cnp-lab27 demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop-frontend Enabled | tail -1 | sed 's/^/  /'
  NS=cf2cnp-lab27 demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop-backend Enabled | tail -1 | sed 's/^/  /'
  k apply -f demos/27-cf2cnp-release/20-shop-default-deny-ingress.yaml >/dev/null
  hit cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/
  hit cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/
}
lab30() {
  say "demo 30 — cf2cnp-lab30: the shop with real paths and HTTP visibility; what the proxy reports (Exercise 0)"
  k apply -f demos/30-l7-rules/10-lab.yaml -f demos/30-l7-rules/20-http-visibility.yaml >/dev/null; ready cf2cnp-lab30
  reset_chapter cf2cnp-lab30; k delete -f demos/30-l7-rules/30-shop-default-deny-ingress.yaml --ignore-not-found >/dev/null 2>&1 || true   # chapter 30's replacement of the visibility policy, from the last pass
  # the observation is the pods' own loops (pos: / and /checkout; the frontend's caller: /api/orders; the stranger: /admin and
  # the backend) — calls.sh is NOT run here: its pos → /admin would be observed, become a rule, and the chapter's 403 would
  # be a 200 (demo 30's lesson: the rule is the intent, so the observation must be the intent); calls.sh is the enforced check
  sleep 20; demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300 2>&1 | head -12 | sed 's/^/  /'
}
lab32() {
  say "demo 32 — the kiosk, a new caller of demo 27's storefront"
  k apply -f demos/32-operator-loop/10-kiosk.yaml >/dev/null; ready cf2cnp-lab27
  hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/
}
lab35() {
  say "demo 35 — the shop platform: six namespaces; probe.sh before any policy (Exercise 0); then audit mode everywhere and the default-deny"
  k apply -f demos/35-shop-platform/10-platform.yaml >/dev/null
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews shop-clients; do ready "$ns"; done
  reset_chapter shop-edge shop-core shop-payments shop-merchant shop-reviews shop-clients
  demos/35-shop-platform/probe.sh 2>&1 | sed 's/^/  /'
  # the observation under audit is the platform's own loops; probe.sh's last line (the shopper straight at the catalog) is
  # the call the chapter proves was never observed — so probe.sh runs before audit here, and in the rounds only once enforced
  demos/35-shop-platform/audit-all.sh Enabled 2>&1 | tail -2 | sed 's/^/  /'
  k apply -f demos/35-shop-platform/20-default-deny-ingress.yaml >/dev/null
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
  # captured, then searched: `… | grep -q` closes the pipe on the first match and, under pipefail, the producer's SIGPIPE
  # became the check's failure on one node of two (run 34908075674) — gotcha #93's shape
  local imgs; for c in "$CTX" "$PEER_CTX"; do imgs=$(docker exec "${c#kind-}-control-plane" crictl images 2>/dev/null || true); printf '%s\n' "$imgs" | grep -q 'bankdemo' || die "bankdemo:local is not in ${c#kind-}'s nodes — scripts/lab-images.sh first"; done
  kubectl --context "$PEER_CTX" apply -f demos/15-bank/10-poc2.yaml >/dev/null; sleep 2; kubectl --context "$PEER_CTX" apply -f demos/15-bank/10-poc2.yaml >/dev/null   # the SA race the guide names
  kubectl --context "$PEER_CTX" -n bank rollout status sts/postgres --timeout=5m >/dev/null; kubectl --context "$PEER_CTX" -n bank rollout status deploy/accounts deploy/payments --timeout=5m >/dev/null
  k apply -f demos/15-bank/20-poc1.yaml >/dev/null; sleep 2; k apply -f demos/15-bank/20-poc1.yaml >/dev/null
  k -n bank rollout status sts/redis deploy/payments deploy/api deploy/web --timeout=5m >/dev/null
  k apply -f demos/15-bank/30-gateway.yaml >/dev/null
  # demo 15's in-cluster check runs HERE, before demo 19's cell — the demos' own order. The cell denies every namespace
  # but its own, so a check from forensic after it hangs on curls with no timeout (run 34922062949: the report step sat
  # 94 minutes on it). Its output is kept for the report; a run without the forensic client notes that instead.
  mkdir -p "${LAB_CHECKS_DIR:-captures/checks}"
  # a re-run (a laptop; the runner never re-runs) finds the cell from the last pass in both clusters, and "before the cell"
  # would then run under its deny — every curl from forensic dropped, the check hung 36 minutes on the M5 (gotcha #112).
  # The demos' order is restored: the cell removed here, re-applied below. On a first run there is nothing to remove.
  for c in "$CTX" "$PEER_CTX"; do
    kubectl --context "$c" delete ciliumclusterwidenetworkpolicies bank-cell-baseline --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context "$c" -n bank delete ciliumnetworkpolicies -l rendered-from=intent.yaml --ignore-not-found >/dev/null 2>&1 || true
  done
  if k -n forensic get pod client >/dev/null 2>&1; then
    say "demo 15 — the bank across the mesh, from inside (demos/15-bank/check.sh from forensic/client), before the cell"
    # the check's stdout AND stderr go to its file below, so the ceiling's absence is said here, where the log can see it (review C4)
    command -v timeout >/dev/null || command -v gtimeout >/dev/null || echo "::warning::no timeout/gtimeout on this host — demos/15-bank/check.sh runs with no 15m ceiling (brew install coreutils)"
    # ROOT_CA: step 7 of the check goes through the Gateway on the wildcard certificate — without this lab's root it read
    # docs/root-ca.crt (the laptop's) and printed `https://bank.poc.local -> http 000` (run 34930321170)
    ( export ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}"; deadline 15m demos/15-bank/check.sh ) > "${LAB_CHECKS_DIR:-captures/checks}/demo15-check.txt" 2>&1 || echo "  check.sh exited $? (the output is kept)"
    grep -E '^== |served|TOTAL|payments backends|https://bank|^ +[0-9]+ (poc1|poc2|FAIL)$|requests:|stored_in_redis|balance now' "${LAB_CHECKS_DIR:-captures/checks}/demo15-check.txt" | head -40 | sed 's/^/  /'
  else echo "  demo 15's in-cluster check skipped: no forensic/client (scripts/lab-apps.sh forensic first)" | tee "${LAB_CHECKS_DIR:-captures/checks}/demo15-check.txt"; fi
  for c in "$CTX" "$PEER_CTX"; do kubectl --context "$c" apply -f demos/19-zero-trust-cell/10-platform-baseline.yaml -f demos/19-zero-trust-cell/rendered/cell-policies.yaml >/dev/null; done
  echo "bank up in both clusters; $(k -n bank get cnp --no-headers | wc -l | tr -d ' ') cell policies in poc1, $(kubectl --context "$PEER_CTX" -n bank get cnp --no-headers | wc -l | tr -d ' ') in poc2"
  bank_traffic
}
bank_traffic() { # demo 15's payments through the Gateway (CA: this lab's root, exported by lab-stack.sh), demo 19's egress probe (the drops)
  CA="${ROOT_CA:-.tmp/root-ca.crt}" demos/15-bank/exercise.sh 5 chk-1001 2>&1 | tail -3 | sed 's/^/  /' || true
  demos/19-zero-trust-cell/egress-test.sh "${CTX#kind-}" 2>&1 | tail -4 | sed 's/^/  /' || true
}
dns() {
  say "demo 31 — the chapter's recorded toFQDNs policy on cf2cnp-lab/pos (the DNS proxy on: names in Hubble's flows and the DNS dashboard)"
  # the chapter's END state, not its CIDR step: cnp-pos-dns-visibility.yaml pins example.com's address of the day it was recorded
  # (toCIDR 104.20.23.154/32) and dropped every world flow of the last run (the observer's flows dashboard: example.com 39% of
  # the drops); the toFQDNs file names example.com:443 and nothing else — port 80 and cilium.io stay dropped until chapter 31
  # regenerates from what pos actually does (scripts/lab-policies.sh 31)
  k apply -f demos/31-dns-visibility/policies/cnp-pos-fqdn.yaml >/dev/null
  hit cf2cnp-lab pos - https://example.com/; hit cf2cnp-lab pos - http://example.com/; hit cf2cnp-lab pos - https://cilium.io/
}
forensic() {
  say "demo 11 — the rig's client pod in forensic (netshoot: curl + jq), the pod demo 15's in-cluster check runs from"
  # the rig pins its pods to <cluster>-worker2 (a node the CI clusters do not have: clusters/ci/poc1.yaml is one control
  # plane and one worker), so the Namespace and the client Pod are taken from the rig's file with the affinity removed —
  # the file stays the source (its image, its name), the lab states the one deviation
  # kubectl prints one JSON object per document here, not a List: slurped into one (gotcha #106). The namespace first, then
  # the pod once trust-manager has written the enterprise-root ConfigMap into it (demo 36) — the rig's client mounts it
  local rig; rig=$(k create --dry-run=client -o json -f demos/11-kube-proxy-vs-cilium/00-rig.yaml | jq -s '{apiVersion: "v1", kind: "List", items: map(select(.kind == "Namespace" or (.kind == "Pod" and .metadata.name == "client")) | del(.spec.affinity))}')
  printf '%s' "$rig" | jq '.items |= map(select(.kind == "Namespace"))' | k apply -f - >/dev/null
  local _i; for _i in $(seq 1 15); do k -n forensic get cm enterprise-root >/dev/null 2>&1 && break; sleep 2; done
  k -n forensic get cm enterprise-root >/dev/null 2>&1 || echo "  (no enterprise-root ConfigMap in forensic after 30 s — demo 36's Bundle not synced; the mount stays empty)"
  printf '%s' "$rig" | jq '.items |= map(select(.kind == "Pod"))' | k apply -f - >/dev/null
  k -n forensic wait --for=condition=Ready pod/client --timeout=3m >/dev/null || { k -n forensic get pod client; die "forensic/client did not become Ready"; }
  echo "  forensic/client Ready on $(k -n forensic get pod client -o jsonpath='{.spec.nodeName}'): $(k -n forensic exec client -- sh -c 'curl --version | head -1; jq --version; ls /etc/enterprise-root/' 2>/dev/null | tr '\n' ' ')"
}
springboot() {
  say "demo 20 — the petclinic in springboot: six Spring Boot services (the collector's zipkin receiver takes their spans), the route, the memory"
  # the host's memory before and after: `free` is Linux's (the runner); a Mac has none, and under pipefail the failed
  # substitution's status ended the whole lab here with nothing printed (the M5, 2026-09-15) — so the measurement is
  # optional, its absence is said, and the pipeline cannot fail the assignment
  used_mb() { { free -m 2>/dev/null || true; } | awk '/^Mem:/ {print $3}'; }
  local before_used; before_used=$(used_mb)
  k apply -f demos/20-springboot/10-petclinic.yaml >/dev/null
  # the order the init containers enforce: config-server, then discovery-server, then the four; 10 min per cold JVM
  local d; for d in config-server discovery-server customers-service vets-service visits-service api-gateway; do
    k -n springboot rollout status deploy/"$d" --timeout=10m >/dev/null || { k -n springboot get pods; die "springboot/$d did not roll out"; }
  done
  k apply -f demos/20-springboot/20-gateway.yaml >/dev/null
  local _i; for _i in $(seq 1 30); do [ "$(k -n routes get httproute petclinic -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = True ] && break; sleep 2; done
  echo "  six Deployments rolled out; the route: Accepted=$(k -n routes get httproute petclinic -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  # Ready is not registered: the gateway routes through Eureka (lb://…), whose client-side cache refreshes every 30 s
  # (gotcha #65) — the first check straight after the rollouts saw 405, 500 and "failed" (run 34922062949). Wait until
  # Eureka lists the four applications UP, then the cache window.
  local apps _j; for _j in $(seq 1 36); do
    apps=$(k -n springboot exec deploy/discovery-server -c discovery-server -- curl -s -m 5 -H accept:application/json http://localhost:8761/eureka/apps 2>/dev/null | python3 -c 'import json,sys; print(sum(1 for a in json.load(sys.stdin)["applications"]["application"] if a["instance"][0]["status"]=="UP"))' 2>/dev/null || echo 0)
    [ "${apps:-0}" -ge 4 ] && break; sleep 5
  done
  echo "  Eureka: ${apps:-0} applications UP after $(( _j * 5 )) s; the gateway's 30 s cache next"; sleep 35
  # the measurement the operator asked for: what six JVMs cost this host — the runner's used memory before and after,
  # and what the pods themselves use (metrics-server, installed by lab-up), against what the manifest requests and limits
  echo "  memory: host used ${before_used:-?(no free on this host)} MB → $(used_mb) MB; requests $(k -n springboot get pods -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' | sed 's/Mi//' | awk '{s+=$1} END {print s}') Mi, limits $(k -n springboot get pods -o jsonpath='{range .items[*].spec.containers[*]}{.resources.limits.memory}{"\n"}{end}' | sed 's/Mi//' | awk '{s+=$1} END {print s}') Mi"
  k top pods -n springboot --no-headers 2>/dev/null | awk '{printf "    %-40s %s %s\n", $1, $2, $3}' || echo "    (kubectl top: no samples yet)"
  petclinic_traffic
}
petclinic_traffic() { ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}" demos/20-springboot/check.sh 3 2>&1 | sed 's/^/  /' || true; }
trust() {
  say "demo 36 — trust/curl: a labelled client with no mount in its manifest; what admission added; a curl with no flag"
  k get mutatingpolicy mount-enterprise-root >/dev/null 2>&1 || die "no MutatingPolicy mount-enterprise-root — scripts/lab-stack.sh kyverno first"
  k apply -f demos/36-trust-everywhere/30-labelled-client.yaml >/dev/null
  local _i; for _i in $(seq 1 15); do k -n trust get cm enterprise-root >/dev/null 2>&1 && break; sleep 2; done   # trust-manager fills a new namespace in seconds
  ready trust
  scripts/lab-trust.sh labelled-check "$CTX" trust curl "$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')" bank.poc.local
}

rounds() { # <minutes> — every generator, round after round: a dashboard's rate windows need minutes, not one burst
  local minutes="${1:-5}" end round=0; end=$(( $(date +%s) + minutes * 60 ))
  say "traffic for $minutes minutes — every lab's generators, round after round"
  while [ "$(date +%s)" -lt "$end" ]; do
    round=$((round + 1))
    { hit cf2cnp-lab pos - http://shop.cf2cnp-lab/; hit cf2cnp-lab stranger - http://shop.cf2cnp-lab/; hit cf2cnp-lab pos - http://example.com/
      # what the verdicts dashboard's other rows read (demo 28): ICMP echo and a name that does not exist (an NXDOMAIN answer
      # through pos's DNS proxy). The stranger pings the shop POD — a ClusterIP is L4 only, ICMP to it is no flow into the
      # namespace — and it is the stranger, not pos: pos's egress flows are chapter 31's input, and an ICMP flow there would
      # become a rule without a port. Under audit the echo is answered; once shop is enforced it is not (the "missing" panels)
      k -n cf2cnp-lab exec stranger -- ping -c 1 -W 1 "$(pod_ip cf2cnp-lab app=shop)"; k -n cf2cnp-lab exec pos -- nslookup does-not-exist.example.invalid
      hit cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/; hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/
      k -n cf2cnp-lab30 exec stranger -c client -- ping -c 1 -W 1 "$(pod_ip cf2cnp-lab30 app=shop-frontend)"
      # the demos' full case lists (pos → /admin, the shopper straight at the catalog) only once the namespace is enforced —
      # before that they would be observed and become rules; the pods' own loops are the observation
      k -n cf2cnp-lab30 get cnp shop-default-deny-ingress >/dev/null 2>&1 && demos/30-l7-rules/calls.sh
      k -n shop-core get cnp catalog >/dev/null 2>&1 && demos/35-shop-platform/probe.sh
      k get pod tiefighter >/dev/null 2>&1 && sw_traffic
      k -n bank get deploy api >/dev/null 2>&1 && bank_traffic
      k -n springboot get deploy api-gateway >/dev/null 2>&1 && petclinic_traffic
    } >/dev/null 2>&1 || true
    printf '  round %d at %s\n' "$round" "$(date +%H:%M:%S)"; sleep 15
  done
}
prom() { k get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")' 2>/dev/null || true; }
wait_for_data() { # until Prometheus, Loki and Tempo hold what the dashboards read — each a test: nothing after 5 minutes fails the step
  say "waiting until Prometheus, Loki and Tempo hold what the dashboards read"
  local q _i n missing=0
  for q in 'sum(rate(hubble_http_requests_total[5m]))' 'sum(hubble_dns_queries_total)' 'sum(hubble_policy_verdicts_total{action="dropped"})' 'sum(hubble_flows_processed_total)' 'sum(hubble_icmp_total)'; do
    for _i in $(seq 1 30); do n=$(prom "$q"); [ -n "$n" ] && [ "$n" != "0" ] && break; sleep 10; done
    printf '  %-56s %s\n' "$q" "${n:-nothing after 5 min}"; [ -n "$n" ] && [ "$n" != "0" ] || missing=$((missing + 1))
  done
  for _i in $(seq 1 30); do
    n=$(k get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query?query=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("sum(count_over_time({namespace=\"hubble-observer\",container=\"hubble-observer\"}[15m]))"))')" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "0")' 2>/dev/null || echo 0)
    [ "${n:-0}" != "0" ] && break; sleep 10
  done
  printf '  %-56s %s\n' "Loki: observer lines, last 15 min" "${n:-0}"; [ "${n:-0}" != "0" ] || missing=$((missing + 1))
  # Tempo: traces from EACH cluster (demo 23's query, the operator's "tempo-central shows data from both poc1 and poc2") — OBI on
  # the bank in both clusters through each cluster's own collector; a cluster with none is a failure, not a line
  if k -n monitoring get svc tempo >/dev/null 2>&1; then
    local c t; for c in "${CTX#kind-}" "${PEER_CTX#kind-}"; do
      for _i in $(seq 1 30); do
        t=$(k get --raw "/api/v1/namespaces/monitoring/services/tempo:3200/proxy/api/search?q=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote("{ resource.k8s.cluster.name = \"" + sys.argv[1] + "\" }"))' "$c")&start=$(( $(date +%s) - 1200 ))&end=$(date +%s)&limit=200" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("traces",[])))' 2>/dev/null || echo 0)
        [ "${t:-0}" -gt 0 ] && break; sleep 10
      done
      printf '  %-56s %s\n' "Tempo: traces from $c, last 20 min" "${t:-0}"; [ "${t:-0}" -gt 0 ] || missing=$((missing + 1))
    done
  else echo "  Tempo: not installed, traces not checked"; fi
  [ "$missing" -eq 0 ] || die "$missing of the stores the dashboards read hold nothing after the traffic (the lines above name them)"
}
traffic() { rounds "${1:-5}"; wait_for_data; }

[ $# -ge 1 ] || { echo "usage: $0 all | lab26 lab27 lab30 lab32 lab35 app02 forensic bank dns springboot trust | rounds <minutes> | wait | traffic <minutes>"; exit 2; }
# LAB_APPS_SKIP=springboot (space-separated) leaves a lab out of `all` — the petclinic is the one that costs memory (demo 20's header)
if [ "$1" = all ]; then
  labs=(); for l in lab26 lab27 lab30 lab32 lab35 app02 forensic bank dns springboot trust; do case " ${LAB_APPS_SKIP:-} " in *" $l "*) ;; *) labs+=("$l");; esac; done; set -- "${labs[@]}"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    lab26|lab27|lab30|lab32|lab35|app02|bank|dns|forensic|springboot|trust) "$1"; shift;;
    rounds) rounds "${2:-5}"; shift 2;;
    wait) wait_for_data; shift;;
    traffic) traffic "${2:-5}"; shift 2;;
    *) die "unknown lab $1";;
  esac
done
say "labs on ${CTX#kind-}: done"
