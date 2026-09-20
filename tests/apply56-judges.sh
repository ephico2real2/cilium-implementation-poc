#!/usr/bin/env bash
# test: demo 56 apply.sh failure-B judges (PATH-stub; the functions are extracted from apply.sh, nothing is applied).
#   (a) kubectl failing on the node read ("Ready=? …") must NOT be counted as the node going not-ready
#   (b) Ready=Unknown IS counted; the summary carries post_notready ok=/fail= and the EG controller's node
#   (c) apply.sh has no BusyBox-rejected `traceroute -T` and waits for shopapi with `rollout status`
# usage: bash tests/apply56-judges.sh   (exit 0 = test passes)
set -uo pipefail
R=${R:-$(cd "$(dirname "$0")/.." && pwd)}
APPLY=${APPLY:-$R/demos/56-kube-vip-bgp/apply.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# the judges under test, lifted verbatim from apply.sh (function definitions only)
for fn in node_path_count leaf_node_paths leaf_peer_state worker_ready_line ready_eps_of shopapi_ready_eps door_ready_eps eg_controller_node failure_silent_node; do
  awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) *\\{" {p=1} p {print} p && /^}/ {p=0}' "$APPLY"
done > "$T/fns.sh"
grep -q '^failure_silent_node()' "$T/fns.sh" || { echo "TEST FAIL: failure_silent_node not found in $APPLY"; exit 1; }

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *inspect*) echo 172.19.0.3; exit 0 ;;
  pause*|unpause*) exit 0 ;;
  *'show ip bgp'*) printf '%s\n' '{"prefix":"x","paths":[{"nexthop":"172.19.0.2"}]}'; exit 0 ;;
  *'show bgp summary json'*) printf '%s\n' '{"ipv4Unicast":{"peers":{"172.19.0.2":{"state":"Established","remoteAs":65021}}}}'; exit 0 ;;
  *curl*) printf '000'; exit 28 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
# KUBECTL_MODE=dead: every kubectl fails.  KUBECTL_MODE=unknown: the node is Ready=Unknown, endpoints pruned, EG on the worker.
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [ "$KUBECTL_MODE" = dead ]; then echo "Unable to connect to the server: connection refused" >&2; exit 1; fi
case "$*" in
  *get\ node*) printf 'Ready=Unknown lastTransitionTime=2026-09-20T05:25:00Z' ;;
  *endpointslice*) printf '%s' '{"items":[{"endpoints":[{"conditions":{"ready":true}},{"conditions":{"ready":false}}]}]}' ;;
  *control-plane=envoy-gateway*) printf 'eg-poc1-worker ' ;;
  *) printf '' ;;
esac
STUB
chmod +x "$T/bin/"*
export CTX=kind-eg-poc1 CLIENT=c HTTP_HOST=h HTTP_ADDR=10.98.0.10 PROJECT=p FABRIC=f SILENT_S=3 TICK_S=1 RECOVERY_S=2

run_b() { (PATH="$T/bin:/usr/bin:/bin" KUBECTL_MODE="$1" bash -c "source '$T/fns.sh'; failure_silent_node" 2>&1); }

# (a) dead kubectl → node_notready_s=none
out=$(run_b dead)
printf '%s\n' "$out" | grep -q 'B summary: .*node_notready_s=none' \
  || { echo "TEST FAIL (a): a failing kubectl was counted as the node going not-ready"; printf '%s\n' "$out" | tail -2; exit 1; }

# (b) Ready=Unknown → node_notready_s set, post_notready counted, EG node named
out=$(run_b unknown)
printf '%s\n' "$out" | grep -Eq 'B summary: .*node_notready_s=[0-9]+ ' \
  || { echo "TEST FAIL (b): Ready=Unknown was not counted as not-ready"; printf '%s\n' "$out" | tail -2; exit 1; }
printf '%s\n' "$out" | grep -Eq 'post_notready ok=[0-9]+ fail=[1-9][0-9]*' \
  || { echo "TEST FAIL (b): the summary does not count the probes after the node went not-ready"; printf '%s\n' "$out" | tail -2; exit 1; }
printf '%s\n' "$out" | grep -q 'eg_controller_node=eg-poc1-worker' \
  || { echo "TEST FAIL (b): the summary does not name the Envoy Gateway controller's node"; printf '%s\n' "$out" | tail -2; exit 1; }
printf '%s\n' "$out" | grep -Eq '^t\+[0-9]+s .*door_eps=1' \
  || { echo "TEST FAIL (b): the tick does not report the door Service's ready endpoints"; printf '%s\n' "$out" | head -3; exit 1; }

# (c) the traceroute and the shopapi wait
if grep -nq 'traceroute -T' "$APPLY"; then
  echo "TEST FAIL (c): apply.sh still runs 'traceroute -T' (BusyBox in netshoot rejects -T; the record holds the usage text)"; exit 1
fi
grep -q 'tcptraceroute' "$APPLY" \
  || { echo "TEST FAIL (c): apply.sh does not trace the TCP path with tcptraceroute"; exit 1; }
grep -Eq 'rollout status deploy/shopapi' "$APPLY" \
  || { echo "TEST FAIL (c): apply.sh does not wait for shopapi's rollout to COMPLETE (condition=Available passes a stuck rollout)"; exit 1; }

echo "TEST PASS: dead kubectl is not 'not ready'; Ready=Unknown is; post-notready probes and the EG controller's node are in the summary; tcptraceroute; rollout status"
exit 0
