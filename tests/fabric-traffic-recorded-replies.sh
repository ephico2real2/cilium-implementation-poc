#!/usr/bin/env bash
# test: scripts/fabric-traffic.sh counts a failed recorded reply as a FAIL.
#
# Section 4 records six curls from client0 through record.sh. The script runs
# without set -e (its rows are the verdict) and record.sh returns curl's rc
# under RECORD_STRICT=1 — and nothing read it: a reply that failed was written
# to the transcript as "[exit code: 22]" under a footer that still said
# "0 FAIL", exit 0. Same shape as the e2e's swallowed check.sh.
#
# PATH-stub: docker/kubectl/curl answer what a healthy lab answers, except
# that the recorded reply numbered TRAFFIC_STUB_FAIL_AT (default 3) exits 22
# with no body. record.sh is the real one.
#   usage: bash tests/fabric-traffic-recorded-replies.sh   (no lab needed)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
# The bash the script's shebang resolves to, captured BEFORE PATH is narrowed
# to the stubs: /bin/bash 3.2 treats an empty array as unbound under set -u
# and the script dies at its COMPOSE line, which is not what is under test.
BASH_BIN=$(command -v bash)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/scripts" "$T/repo/clusters"
cp "$R/scripts/fabric-traffic.sh" "$R/scripts/record.sh" "$T/repo/scripts/"
printf 'kube-vip.io/loadbalancerIPs: "10.198.0.46"\ncidr-demo46: 10.198.0.46/32\n' > "$T/repo/clusters/bgp-fabric-probe.yaml"
export STUB_STATE="$T/state"; mkdir -p "$STUB_STATE"

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *"vtysh -c show route-map SERVERS-IN json"*)
    printf '{"bgpd":{"SERVERS-IN":{"rules":[{"sequenceNumber":10,"invoked":4}]}}}' ;;
  *"unicast 10.198.0.46/32 json"*)
    printf '{"paths":[{"aspath":{"string":"65021"},"nexthops":[{"ip":"10.200.1.3"},{"ip":"10.200.1.11"}]}]}' ;;
  *"unicast 10.198.0.46/32"*)
    echo "BGP routing table entry for 10.198.0.46/32" ;;
  *"spine ip route show 10.198.0.46"*)
    printf '10.198.0.46 nhid 30 proto bgp metric 20\n\tnexthop via 10.200.1.3 dev eth1 weight 1\n\tnexthop via 10.200.1.11 dev eth2 weight 1\n' ;;
  *"ip route replace"*) exit 0 ;;
  *"ip route show 10.200.0.0/16"*) echo "10.200.0.0/16 via 172.20.254.11 dev eth0" ;;
  *"client0 traceroute"*) printf ' 1  10.200.1.17  0.1 ms\n 2  10.200.1.3  0.2 ms\n' ;;
  *"client0 curl"*"-o /dev/null"*) exit 0 ;;
  *"client0 curl -fsS --max-time 5"*) echo "Hostname: demo46-probe-7c9b"; ;;
  *"client0 curl -fsS --max-time 3 http://10.198.0.46/")
    n=$(( $(cat "$STUB_STATE/replies" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_STATE/replies"
    if [ "$n" -eq "${TRAFFIC_STUB_FAIL_AT:-3}" ]; then echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; fi
    echo "Hostname: demo46-probe-7c9b" ;;
  *) exit 0 ;;
esac
STUB
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *"get svc demo46-probe"*jsonpath*) printf '10.198.0.46' ;;
  *"get nodes"*jsonpath*) printf 'stub-control-plane\n' ;;
  *"rollout status"*) echo 'deployment "demo46-probe" successfully rolled out' ;;
  *) echo "ok: $a" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho %s\n' "'{\"vips\":[\"10.198.0.46\"]}'" > "$T/bin/curl"
chmod +x "$T/bin/"*

run_traffic() { # TRAFFIC_STUB_FAIL_AT
  rm -f "$STUB_STATE/replies"
  (cd "$T/repo" && TRAFFIC_STUB_FAIL_AT="$1" CTX_DOCKER='' PATH="$T/bin:/usr/bin:/bin" \
     "$BASH_BIN" scripts/fabric-traffic.sh 2>/dev/null); echo "rc=$?"
}

out=$(run_traffic 3); rc=$(printf '%s\n' "$out" | tail -1)
tx="$T/repo/demos/46-bgp-fabric-colima/output/transcript.txt"
grep -q '^\[exit code: 22\]$' "$tx" 2>/dev/null \
  || { echo "TEST FAIL: the stub's failed reply was not recorded — the harness is wrong, not the script"; exit 1; }
if [ "$rc" = "rc=0" ] || ! printf '%s\n' "$out" | grep -q 'demo 46 traffic: [1-9][0-9]* FAIL'; then
  echo "TEST FAIL: a recorded reply exited 22 and the script said '$(printf '%s\n' "$out" | grep 'demo 46 traffic:')' ($rc)"
  exit 1
fi
printf '%s\n' "$out" | grep -qE '^  FAIL   6 recorded replies from client0 +5/6 answered' \
  || { echo "TEST FAIL: no FAIL row naming the 5/6 recorded replies"; printf '%s\n' "$out" | grep -E '^  (PASS|FAIL)'; exit 1; }

out=$(run_traffic 0); rc=$(printf '%s\n' "$out" | tail -1)
[ "$rc" = "rc=0" ] && printf '%s\n' "$out" | grep -q 'demo 46 traffic: 0 FAIL' \
  || { echo "TEST FAIL: with every reply answered the script did not exit 0 ($rc)"; exit 1; }
echo "TEST PASS: a failed recorded reply is a FAIL row and a non-zero exit; six good replies exit 0"
