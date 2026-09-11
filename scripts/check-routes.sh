#!/usr/bin/env bash
# check-routes.sh — prove, from OUTSIDE the cluster, that every example in the `routes` namespace
# (demo 09) answers through the Gateway at its reserved gateway-pool address, and that Hubble UI is
# served through the same Gateway URL. Names are pinned with curl --resolve, so it works with NO
# /etc/hosts entries (scripts/hosts-entries.sh prints the lines if you want the names in a browser).
#
# Run from the Mac (or a Linux host that can reach the docker network):
#   scripts/check-routes.sh                     # uses the live Gateway address
#   scripts/record.sh demos/09-routes/output/access-check.txt scripts/check-routes.sh   # keep the evidence
#
# Exit code is the number of failed checks, so it can gate a pipeline.
set -uo pipefail
CTX="${CTX:-kind-poc1}"
CA="${CA:-docs/root-ca.crt}"
GW="$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')"
FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
want() { # want <expected-code> <label> <curl args...>
  local exp="$1" label="$2"; shift 2
  local got; got="$(curl -s -o /dev/null -w '%{http_code}' "$@")"
  [ "$got" = "$exp" ] && ok "$label -> $got" || bad "$label -> $got (expected $exp)"
}

echo "Gateway routes-gw address: $GW   (must be inside gateway-pool 172.18.255.240-250)"
kubectl --context "$CTX" -n routes get httproute,grpcroute,tcproute -o custom-columns='KIND:.kind,NAME:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,RESOLVED:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status'
echo

echo "1. HTTPRoute x3 over HTTPS, certificate chain verified against the enterprise root ($CA)"
for h in web.poc.local anything-at-all.poc.local; do want 200 "https://$h/ (wildcard listener, *.poc.local cert)" --cacert "$CA" --resolve "$h:443:$GW" "https://$h/"; done
want 200 "https://exact.example.test/ (exact listener, its own cert)" --cacert "$CA" --resolve "exact.example.test:443:$GW" "https://exact.example.test/"
want 404 "https://nobody.poc.local/ (under the wildcard but NO route -> Gateway 404)" --cacert "$CA" --resolve "nobody.poc.local:443:$GW" "https://nobody.poc.local/"
echo "   SNI -> certificate presented:"
for h in web.poc.local exact.example.test; do
  san="$(echo | openssl s_client -connect "$GW:443" -servername "$h" -CAfile "$CA" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')"
  printf '     %-20s %s\n' "$h" "$san"
done
echo

echo "2. HTTPRoute over plain HTTP :80 (Host header selects the route)"
want 200 "http://$GW/ Host: web.poc.local" -H 'Host: web.poc.local' "http://$GW/"
echo

echo "3. GRPCRoute (grpcurl runs in a container on the docker network; -authority is the route's hostname)"
h2c="$(docker run --rm --network kind fullstorydev/grpcurl:latest -plaintext -authority grpc.poc.local "$GW:80" grpc.health.v1.Health/Check 2>&1 | tr -d ' \n')"
[ "$h2c" = '{"status":"SERVING"}' ] && ok "h2c :80 Health/Check -> $h2c" || bad "h2c :80 Health/Check -> $h2c"
tls="$(docker run --rm --network kind -v "$PWD/docs:/certs:ro" fullstorydev/grpcurl:latest -cacert /certs/root-ca.crt -authority grpc.poc.local "$GW:443" grpc.health.v1.Health/Check 2>&1 | tr -d ' \n')"
[ "$tls" = '{"status":"SERVING"}' ] && ok "TLS :443 Health/Check, wildcard cert verified -> $tls" || bad "TLS :443 Health/Check -> $tls"
echo

echo "4. TCPRoute :9000 (bytes in, bytes back — no HTTP involved)"
reply="$(printf 'ping from check-routes\n' | nc -w 3 "$GW" 9000 | tr '\n' '|')"
case "$reply" in *"echoed: ping from check-routes"*) ok "tcp echo -> $reply";; *) bad "tcp echo -> '$reply'";; esac
echo

echo "5. Hubble UI through the SAME Gateway URL: https://hubble.poc.local (HTTPRoute in routes -> Service in kube-system via ReferenceGrant)"
want 200 "https://hubble.poc.local/ (index)" --cacert "$CA" --resolve "hubble.poc.local:443:$GW" "https://hubble.poc.local/"
title="$(curl -s --cacert "$CA" --resolve "hubble.poc.local:443:$GW" https://hubble.poc.local/ | grep -o '<title>[^<]*</title>')"
[ "$title" = '<title>Hubble UI</title>' ] && ok "page title $title" || bad "page title '$title'"
for a in $(curl -s --cacert "$CA" --resolve "hubble.poc.local:443:$GW" https://hubble.poc.local/ | grep -oE '(src|href)="[^"]+\.(js|css)"' | sed 's/^[a-z]*="//;s/"$//'); do
  want 200 "asset /$a" --cacert "$CA" --resolve "hubble.poc.local:443:$GW" "https://hubble.poc.local/$a"
done
want 200 "same UI direct at its own LB address (kind-docker-pool) for comparison" "http://172.18.255.201/"
echo "   Hubble's own view of that request (world -> hubble-ui, through the Gateway):"
POD="$(kubectl --context "$CTX" -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=poc1-worker -o jsonpath='{.items[0].metadata.name}')"
kubectl --context "$CTX" -n kube-system exec "$POD" -c cilium-agent -- hubble observe --since 2m --to-label k8s-app=hubble-ui --protocol tcp -o compact 2>/dev/null | grep -v '^E0' | tail -2 | sed 's/^/     /'
echo
echo "FAILED CHECKS: $FAIL"
exit "$FAIL"
