#!/usr/bin/env bash
# test: demo 56 check.sh contract (PATH-stub).
#   (a) a dead docker/kubectl/vtysh produces FAIL rows (never PASS) and exit ≠ 0
#   (b) a JSON with one path where two are required → FAIL
#   (c) an arping reply on the routed address → FAIL
#   (d) no `-k`/`-sk` and no `|| echo 000` in apply.sh or check.sh
# usage: bash tests/check56-contract.sh   (exit 0 = test passes)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/56-kube-vip-bgp/check.sh
APPLY=$R/demos/56-kube-vip-bgp/apply.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/56-kube-vip-bgp" "$T/repo/demos/46-bgp-fabric/fabric" "$T/repo/scripts"
cp "$CHECK" "$T/repo/demos/56-kube-vip-bgp/check.sh"
cp "$APPLY" "$T/repo/demos/56-kube-vip-bgp/apply.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
printf 'name: bgp-fabric\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: overlay\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.lan-eg.yaml"

# (a) dead docker / kubectl / vtysh
printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\necho "Cannot connect to the Docker daemon" >&2; exit 1\n' > "$T/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/kind"
chmod +x "$T/bin/"*

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/56-kube-vip-bgp/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}

if printf '%s\n' "$out" | grep -qE '^  PASS'; then
  echo "TEST FAIL: a dead docker/kubectl produced a PASS row"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out" | grep -qE '^  FAIL' \
  || { echo "TEST FAIL: dead docker/kubectl — no FAIL rows"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: dead docker/kubectl — check.sh exited 0"; exit 1; }

# (b) one path on the spine where two are required
printf '#!/usr/bin/env bash\nprintf "eg-poc1-control-plane\\neg-poc1-worker\\n"\n' > "$T/bin/kind"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *numberReady*) printf '2/2' ;;
  *bgp_enable*) printf 'true' ;;
  *bgp_as*) printf '65021' ;;
  *owning-gateway-name=bgp-http-gw*)
    printf '%s' '{"items":[{"spec":{"loadBalancerClass":"kube-vip.io/kube-vip-class","externalTrafficPolicy":"Cluster"},"status":{"loadBalancer":{"ingress":[{"ip":"10.98.0.10"}]}}}]}' ;;
  *owning-gateway-name=bgp-grpc-gw*)
    printf '%s' '{"items":[{"spec":{"loadBalancerClass":"kube-vip.io/kube-vip-class","externalTrafficPolicy":"Cluster"},"status":{"loadBalancer":{"ingress":[{"ip":"10.98.0.11"}]}}}]}' ;;
  *) printf 'True' ;;
esac
STUB
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *inspect*)
    case "$*" in
      *eg-poc1-control-plane*) echo 172.19.0.2 ;;
      *eg-poc1-worker*) echo 172.19.0.3 ;;
      *) echo 172.19.0.2 ;;
    esac
    exit 0
    ;;
  *'show ip bgp 10.98.0.10/32 json'*)
    printf '%s\n' '{"prefix":"10.98.0.10/32","paths":[{"nexthop":"172.19.0.2"}]}'
    exit 0
    ;;
  *'show ip bgp 10.98.0.11/32 json'*)
    printf '%s\n' '{"prefix":"10.98.0.11/32","paths":[{"nexthop":"172.19.0.2"},{"nexthop":"172.19.0.3"}]}'
    exit 0
    ;;
  *'show bgp summary json'*)
    printf '%s\n' '{"ipv4Unicast":{"peers":{"172.19.0.2":{"state":"Established","remoteAs":65021},"172.19.0.3":{"state":"Established","remoteAs":65021}}}}'
    exit 0
    ;;
  *'show route-map'*)
    printf '%s\n' '{"SERVERS-IN":[{"invoked":4}]}'
    exit 0
    ;;
  *arping*) echo "Timeout"; exit 1 ;;
  *curl*)
    printf 'HTTP/1.1 200 OK\r\nX-Served-By: eg-poc1\r\n\r\n'
    exit 0
    ;;
  *grpcurl*GetOrder*)
    printf '%s\n' '{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
    exit 0
    ;;
  *grpcurl*x-version*)
    printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v2-bbbb","version":"v2"}],"servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
    exit 0
    ;;
  *grpcurl*)
    printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v1-aaaa","version":"v1"}],"servedBy":"grpcdemo-v1-aaaa","version":"v1"}'
    exit 0
    ;;
  *) echo "stub: $*"; exit 1 ;;
esac
STUB
chmod +x "$T/bin/"*

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/56-kube-vip-bgp/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+spine 2 paths for 10\.98\.0\.10/32'; then
  echo "TEST FAIL: one path was accepted as two"
  printf '%s\n' "$out" | grep 'spine 2 paths'
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+spine 2 paths for 10\.98\.0\.10/32' \
  || { echo "TEST FAIL: no FAIL row for one path on .10"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: one path — check.sh exited 0"; exit 1; }

# (c) arping reply on the routed address — same stub, arping answers
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *inspect*)
    case "$*" in
      *eg-poc1-control-plane*) echo 172.19.0.2 ;;
      *eg-poc1-worker*) echo 172.19.0.3 ;;
      *) echo 172.19.0.2 ;;
    esac
    exit 0
    ;;
  *'show ip bgp'*)
    printf '%s\n' '{"prefix":"x","paths":[{"nexthop":"172.19.0.2"},{"nexthop":"172.19.0.3"}]}'
    exit 0
    ;;
  *'show bgp summary json'*)
    printf '%s\n' '{"ipv4Unicast":{"peers":{"172.19.0.2":{"state":"Established","remoteAs":65021},"172.19.0.3":{"state":"Established","remoteAs":65021}}}}'
    exit 0
    ;;
  *'show route-map'*)
    printf '%s\n' '{"SERVERS-IN":[{"invoked":4}]}'
    exit 0
    ;;
  *arping*)
    for i in 1 2 3; do echo "Unicast reply from ${@: -1} [aa:bb:cc:dd:ee:ff] 0.01ms"; done
    exit 0
    ;;
  *curl*)
    printf 'HTTP/1.1 200 OK\r\nX-Served-By: eg-poc1\r\n\r\n'
    exit 0
    ;;
  *grpcurl*GetOrder*)
    printf '%s\n' '{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
    exit 0
    ;;
  *grpcurl*x-version*)
    printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v2-bbbb","version":"v2"}],"servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
    exit 0
    ;;
  *grpcurl*)
    printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v1-aaaa","version":"v1"}],"servedBy":"grpcdemo-v1-aaaa","version":"v1"}'
    exit 0
    ;;
  *) echo "stub: $*"; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/56-kube-vip-bgp/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+arping routed door 10\.98\.0\.10'; then
  echo "TEST FAIL: an arping reply on the routed address PASSed"
  printf '%s\n' "$out" | grep arping
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+arping routed door 10\.98\.0\.10' \
  || { echo "TEST FAIL: no FAIL row for an arping reply on 10.98.0.10"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: arping reply — check.sh exited 0"; exit 1; }

if grep -nE -- '-sk|[[:space:]]-k[[:space:]]|[[:space:]]-k"' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry a skip-verify flag"
  exit 1
fi
if grep -nF '|| echo 000' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry || echo 000"
  exit 1
fi

echo "TEST PASS: dead docker/kubectl → FAIL; one path → FAIL; arping reply on routed address → FAIL; no skip-verify, no || echo 000"
exit 0
