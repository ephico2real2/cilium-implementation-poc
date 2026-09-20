#!/usr/bin/env bash
# test: demo 56 check.sh contract, part 2 (PATH-stub). Appended to tests/check56-contract.sh.
#   (f) a stuck shopapi rollout (readyReplicas=2 from the OLD ReplicaSet, updatedReplicas=1,
#       status.replicas=3, one pod Pending) → the shopapi row FAILs (the ninth run's live state)
#   (g) the docker daemon timing out on the arping run ("Client.Timeout exceeded") → both arping rows FAIL
#   (h) a SERVERS-IN route-map where only sequence 20 (EG-POC2) fired → row 13 FAILs
#   (i) the sessions row does not print fabric-bgp-summary.py's table between the rows
#   (j) the happy stub (rollout complete, busybox 0 responses, seq 10 invoked) → those rows PASS, exit 0
# usage: CHECK=path/to/check.sh bash tests/check56-contract-add.sh   (exit 0 = test passes)
set -uo pipefail
R=${R:-$(cd "$(dirname "$0")/.." && pwd)}
CHECK=${CHECK:-$R/demos/56-kube-vip-bgp/check.sh}
T=$(mktemp -d) || { echo "TEST FAIL: mktemp -d failed"; exit 1; }; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/56-kube-vip-bgp" "$T/repo/demos/46-bgp-fabric/fabric" "$T/repo/scripts"
cp "$CHECK" "$T/repo/demos/56-kube-vip-bgp/check.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
printf 'name: bgp-fabric\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: overlay\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.lan-eg.yaml"
printf '#!/usr/bin/env bash\nprintf "eg-poc1-control-plane\\neg-poc1-worker\\n"\n' > "$T/bin/kind"

# SHOPAPI_STATE: stuck | ok ; ARPING_MODE: daemon-timeout | ok ; RM_MODE: seq20-only | ok
write_stubs() {
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *numberReady*) printf '2/2' ;;
  *bgp_enable*) printf 'true' ;;
  *bgp_as*) printf '65021' ;;
  *get\ pods*owning-gateway-name=*) printf 'eg-poc1-control-plane\neg-poc1-worker\n' ;;
  *get\ deploy*owning-gateway-name=*) printf '2' ;;
  *get\ pods*app=shopapi*)
    if [ "$SHOPAPI_STATE" = stuck ]; then printf '\neg-poc1-control-plane\neg-poc1-worker\n'
    else printf 'eg-poc1-control-plane\neg-poc1-worker\n'; fi ;;
  *get\ deploy\ shopapi*)
    # "{spec.replicas} {readyReplicas} {updatedReplicas} {status.replicas}" for the new judge;
    # the old judge asked only for readyReplicas and reads the first token
    if [ "$SHOPAPI_STATE" = stuck ]; then
      case "$*" in *spec.replicas*) printf '2 2 1 3' ;; *) printf '2' ;; esac
    else
      case "$*" in *spec.replicas*) printf '2 2 2 2' ;; *) printf '2' ;; esac
    fi ;;
  *owning-gateway-name=bgp-http-gw*) printf '%s' '{"items":[{"spec":{"loadBalancerClass":"kube-vip.io/kube-vip-class","externalTrafficPolicy":"Cluster"},"status":{"loadBalancer":{"ingress":[{"ip":"10.98.0.10"}]}}}]}' ;;
  *owning-gateway-name=bgp-grpc-gw*) printf '%s' '{"items":[{"spec":{"loadBalancerClass":"kube-vip.io/kube-vip-class","externalTrafficPolicy":"Cluster"},"status":{"loadBalancer":{"ingress":[{"ip":"10.98.0.11"}]}}}]}' ;;
  *) printf 'True' ;;
esac
STUB
  cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *inspect*) case "$*" in *worker*) echo 172.19.0.3 ;; *) echo 172.19.0.2 ;; esac; exit 0 ;;
  *'show ip bgp'*) printf '%s\n' '{"prefix":"x","paths":[{"nexthop":"172.19.0.2"},{"nexthop":"172.19.0.3"}]}'; exit 0 ;;
  *'show bgp summary json'*) printf '%s\n' '{"ipv4Unicast":{"peers":{"172.19.0.2":{"state":"Established","remoteAs":65021},"172.19.0.3":{"state":"Established","remoteAs":65021}}}}'; exit 0 ;;
  *'show route-map'*)
    if [ "$RM_MODE" = seq20-only ]; then
      printf '%s\n' '{"bgp":{"SERVERS-IN":{"invoked":5,"rules":[{"sequenceNumber":10,"invoked":0,"matchClauses":["ip address prefix-list EG-POC1-VIPS","as-path EG-POC1"]},{"sequenceNumber":20,"invoked":5,"matchClauses":["ip address prefix-list EG-POC2-VIPS","as-path EG-POC2"]}]}}}'
    else
      printf '%s\n' '{"bgp":{"SERVERS-IN":{"invoked":72,"rules":[{"sequenceNumber":10,"invoked":72,"matchClauses":["ip address prefix-list EG-POC1-VIPS","as-path EG-POC1"]},{"sequenceNumber":20,"invoked":0,"matchClauses":["ip address prefix-list EG-POC2-VIPS","as-path EG-POC2"]}]}}}'
    fi; exit 0 ;;
  *arping*)
    if [ "$ARPING_MODE" = daemon-timeout ]; then
      echo "docker: Error response from daemon: context deadline exceeded (Client.Timeout exceeded while awaiting headers)"; exit 125
    else
      printf 'ARPING %s from 172.19.0.6 eth0\nSent 3 probe(s) (0 broadcast(s))\nReceived 0 response(s) (0 request(s), 0 broadcast(s))\n' "${@: -1}"; exit 1
    fi ;;
  *grpcurl*GetOrder*) printf '%s\n' '{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"}'; exit 0 ;;
  *grpcurl*x-version*) printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v2-bbbb","version":"v2"}],"servedBy":"grpcdemo-v2-bbbb","version":"v2"}'; exit 0 ;;
  *grpcurl*) printf '%s\n' '{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v1-aaaa","version":"v1"}],"servedBy":"grpcdemo-v1-aaaa","version":"v1"}'; exit 0 ;;
  *curl*) printf 'HTTP/1.1 200 OK\r\nX-Served-By: eg-poc1\r\n\r\n'; exit 0 ;;
  *) echo "stub: $*"; exit 1 ;;
esac
STUB
  chmod +x "$T/bin/"*
}
run_check() { # → $out $rc
  rc=0
  out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" SHOPAPI_STATE="$1" ARPING_MODE="$2" RM_MODE="$3" \
        bash demos/56-kube-vip-bgp/check.sh 2>/dev/null) || rc=$?
}
write_stubs

# (f) stuck rollout → shopapi row FAIL
run_check stuck ok ok
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+shopapi replicas spread' \
  || { echo "TEST FAIL (f): a stuck shopapi rollout (old-RS pods Ready, new pod Pending) PASSed"; printf '%s\n' "$out" | grep shopapi; exit 1; }

# (g) docker daemon timeout on arping → both arping rows FAIL
run_check ok daemon-timeout ok
n=$(printf '%s\n' "$out" | grep -cE 'FAIL[[:space:]]+arping ')
[ "$n" -eq 2 ] \
  || { echo "TEST FAIL (g): a docker daemon timeout on arping did not FAIL both arping rows (got $n)"; printf '%s\n' "$out" | grep arping; exit 1; }

# (h) only sequence 20 fired → row 13 FAIL
run_check ok ok seq20-only
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+SERVERS-IN' \
  || { echo "TEST FAIL (h): SERVERS-IN with only sequence 20 (EG-POC2) invoked PASSed"; printf '%s\n' "$out" | grep SERVERS-IN; exit 1; }

# (i) no summary table leaked between the rows; (j) the happy stub PASSes those rows and exits 0
run_check ok ok ok
if printf '%s\n' "$out" | grep -Eq $'^[0-9.]+\tEstablished\t'; then
  echo "TEST FAIL (i): fabric-bgp-summary.py's table leaked into the check output"; exit 1
fi
for want in 'PASS[[:space:]]+shopapi replicas spread' 'PASS[[:space:]]+arping routed door' 'PASS[[:space:]]+arping demo 54' 'PASS[[:space:]]+SERVERS-IN'; do
  printf '%s\n' "$out" | grep -Eq "$want" \
    || { echo "TEST FAIL (j): happy stub did not PASS: $want"; printf '%s\n' "$out"; exit 1; }
done
[ "$rc" -eq 0 ] || { echo "TEST FAIL (j): happy stub — check.sh exited $rc"; printf '%s\n' "$out"; exit 1; }

echo "TEST PASS: stuck rollout → FAIL; docker timeout on arping → FAIL; seq-20-only route-map → FAIL; no leaked table; happy stub PASSes"
exit 0
