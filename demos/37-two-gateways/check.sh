#!/usr/bin/env bash
# check.sh — demo 37's proofs, in the order of the plan's phase 2: the two doors, the certificates, the answers,
# the negatives (attachment, the flat hijack, the zoned name, then the admission policy), and RBAC. Evidence printer:
# it exits 0 by design and says on every line what it saw; the words that mean trouble are the report's to count.
#   demos/37-two-gateways/check.sh
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }
CA="${ROOT_CA:-.tmp/root-ca.crt}"
GW240=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
GW243=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

wait_parent() { # ns name — wait until the route has an Accepted reason, or give up
  local ns=$1 name=$2 i reason
  for i in $(seq 1 20); do
    reason=$(k -n "$ns" get httproute "$name" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)
    [ -n "${reason:-}" ] && return 0
    sleep 2
  done
}
say_route() { # ns name — one line: Accepted/reason and ResolvedRefs
  local ns=$1 name=$2
  local acc reason msg res
  acc=$(k -n "$ns" get httproute "$name" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  reason=$(k -n "$ns" get httproute "$name" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)
  msg=$(k -n "$ns" get httproute "$name" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].message}' 2>/dev/null || true)
  res=$(k -n "$ns" get httproute "$name" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
  echo "  $ns/$name: Accepted=${acc:-?} reason=${reason:-?} ResolvedRefs=${res:-?}  ${msg:-}"
}
drop_probe() { k delete httproute -n "$1" "$2" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

echo "== 1. the two doors: addresses, Programmed, every route, the shared Envoy, the L2 leases"
echo "  routes/routes-gw: address=${GW240:-?} Programmed=$(k -n routes get gateway routes-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo '?')  (pinned .240)"
echo "  team-b/team-b-gw: address=${GW243:-?} Programmed=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo '?')  (pinned .243)"
# per listener too: on 1.20.1 the Gateway-level condition was set while the listeners' Programmed=True was never persisted
# (cilium/cilium#48013, fixed in 1.20.2) — a reader on an older agent will see this line disagree with the two above
echo "  listeners (Programmed per listener, the 1.20.2 fix — docs/upstream/releases/cilium-v1.20.2.md):"
for gw in routes/routes-gw team-b/team-b-gw; do
  k -n "${gw%/*}" get gateway "${gw#*/}" -o jsonpath='{range .status.listeners[*]}{.name}{"="}{.conditions[?(@.type=="Programmed")].status}{" "}{end}' 2>/dev/null | sed "s#^#    $gw: #"; echo
done
echo "  routes (team-a and team-b):"
for ns in team-a team-b; do
  k -n "$ns" get httproute -o custom-columns='  NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,REASON:.status.parents[0].conditions[?(@.type=="Accepted")].reason,RESOLVED:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status' --no-headers 2>/dev/null || echo "  $ns: no HTTPRoutes (or namespace missing)"
done
echo "  cilium-dbg envoy admin listeners on each agent, grep cilium-gateway (the shared Envoy)"
k -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | while IFS=$'\t' read -r pod node; do
  [ -z "${pod:-}" ] && continue
  echo "  $node ($pod):"
  k -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg envoy admin listeners 2>/dev/null | grep cilium-gateway | sed 's/^/    /' || echo "    (no cilium-gateway listeners, or cilium-dbg failed)"
done
echo "  L2 lease holders:"
k -n kube-system get leases 2>/dev/null | grep l2announce | sed 's/^/    /' || echo "    (no l2announce leases)"

echo; echo "== 2. the certificates: issuer + SAN from the handshake, verified against $CA"
leaf() { # name addr — openssl s_client → issuer + SAN
  local name=$1 addr=$2 out
  if [ -z "$addr" ] || [ ! -f "$CA" ]; then echo "  $name @$addr: no address or no $CA"; return; fi
  out=$(echo | openssl s_client -servername "$name" -connect "$addr:443" -CAfile "$CA" 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName 2>/dev/null | tr '\n' ' ')
  echo "  $name @$addr: ${out:-no certificate presented}"
}
leaf shop-a.poc.local "$GW240"
leaf shop.team-b.poc.local "$GW243"

echo; echo "== 3. the answers: X-Door and the JSON's app; the http:// 301 for each"
https_ans() { # name addr
  local name=$1 addr=$2 hdr body door app code
  if [ -z "$addr" ] || [ ! -f "$CA" ]; then echo "  https://$name @$addr: no address or no $CA"; return; fi
  hdr=$(mktemp); body=$(mktemp)
  code=$(curl --resolve "$name:443:$addr" --cacert "$CA" -sS -D "$hdr" -o "$body" -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$name/" 2>/dev/null || true)
  [ -n "$code" ] || code="curl-fail"
  door=$(awk 'BEGIN{IGNORECASE=1} /^x-door:/{gsub(/\r/,""); print $2; exit}' "$hdr")
  app=$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("app","?"))
except Exception: print("?")' < "$body" 2>/dev/null || echo "?")
  echo "  https://$name @$addr: HTTP ${code} X-Door=${door:-?} app=${app}"
  rm -f "$hdr" "$body"
}
http_301() { # name addr
  local name=$1 addr=$2 hdr loc code
  if [ -z "$addr" ]; then echo "  http://$name @$addr: no address"; return; fi
  hdr=$(mktemp)
  code=$(curl --resolve "$name:80:$addr" -sS -D "$hdr" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://$name/" 2>/dev/null || true)
  [ -n "$code" ] || code="curl-fail"
  loc=$(awk 'BEGIN{IGNORECASE=1} /^location:/{gsub(/\r/,""); print $2; exit}' "$hdr")
  echo "  http://$name @$addr: HTTP ${code} Location=${loc:-?}  (want 301 to https)"
  rm -f "$hdr"
}
https_ans shop-a.poc.local "$GW240"
https_ans shop.team-b.poc.local "$GW243"
https_ans shop-a.team-b.poc.local "$GW243"
http_301 shop-a.poc.local "$GW240"
http_301 shop.team-b.poc.local "$GW243"
http_301 shop-a.team-b.poc.local "$GW243"

echo; echo "== 4. the negatives: attachment, the flat hijack, the zoned name, then the admission policy"
# Drop leftovers so a rerun can still show the hijack; the policy is re-applied at the end of this section and left.
drop_probe team-b demo37-tb-on-rgw
drop_probe team-a demo37-ta-on-tbgw
drop_probe team-a demo37-hijack-flat
drop_probe team-a demo37-hijack-zoned
k delete validatingadmissionpolicybinding httproute-own-zone --ignore-not-found >/dev/null 2>&1 || true
k delete validatingadmissionpolicy httproute-own-zone --ignore-not-found >/dev/null 2>&1 || true

echo "  -- team-b route on routes-gw (unlabelled namespace; want Accepted reason NotAllowedByListeners)"
k apply -f - >/dev/null <<'EOF' || true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo37-tb-on-rgw, namespace: team-b}
spec:
  parentRefs: [{name: routes-gw, namespace: routes, sectionName: https-wildcard}]
  hostnames: ["probe-tb.poc.local"]
  rules:
    - backendRefs: [{name: shop, port: 8080}]
EOF
wait_parent team-b demo37-tb-on-rgw
say_route team-b demo37-tb-on-rgw
drop_probe team-b demo37-tb-on-rgw

echo "  -- team-a route on team-b-gw (from: Same; want refused)"
k apply -f - >/dev/null <<'EOF' || true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo37-ta-on-tbgw, namespace: team-a}
spec:
  parentRefs: [{name: team-b-gw, namespace: team-b, sectionName: https}]
  hostnames: ["probe-ta.team-b.poc.local"]
  rules:
    - backendRefs: [{name: shop, port: 8080}]
EOF
wait_parent team-a demo37-ta-on-tbgw
say_route team-a demo37-ta-on-tbgw
drop_probe team-a demo37-ta-on-tbgw

echo "  -- team-a claims shop-b.poc.local on routes-gw (flat-name hijack: naming cannot stop this)"
k apply -f - >/dev/null <<'EOF' || true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo37-hijack-flat, namespace: team-a}
spec:
  parentRefs: [{name: routes-gw, namespace: routes, sectionName: https-wildcard}]
  hostnames: ["shop-b.poc.local"]
  rules:
    - backendRefs: [{name: shop, port: 8080}]
      filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier: {set: [{name: X-Door, value: routes-gw}]}
EOF
wait_parent team-a demo37-hijack-flat
say_route team-a demo37-hijack-flat
https_ans shop-b.poc.local "$GW240"
echo "  (the hijack, served with a valid *.poc.local certificate at routes-gw)"
drop_probe team-a demo37-hijack-flat

echo "  -- team-a claims shop.team-b.poc.local on routes-gw (zoned; attaches, TLS at .240 fails, .243 answers)"
k apply -f - >/dev/null <<'EOF' || true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo37-hijack-zoned, namespace: team-a}
spec:
  parentRefs: [{name: routes-gw, namespace: routes, sectionName: https-wildcard}]
  hostnames: ["shop.team-b.poc.local"]
  rules:
    - backendRefs: [{name: shop, port: 8080}]
EOF
wait_parent team-a demo37-hijack-zoned
say_route team-a demo37-hijack-zoned
if [ -n "$GW240" ] && [ -f "$CA" ]; then
  zoned=$(curl --resolve "shop.team-b.poc.local:443:$GW240" --cacert "$CA" -sS -o /dev/null -w 'ssl_verify_result=%{ssl_verify_result} http=%{http_code}' --connect-timeout 5 --max-time 10 "https://shop.team-b.poc.local/" 2>&1 || true)
  echo "  shop.team-b.poc.local @$GW240: ${zoned}  (the *.poc.local leaf does not cover a team name)"
else
  echo "  shop.team-b.poc.local @$GW240: no address or no $CA"
fi
https_ans shop.team-b.poc.local "$GW243"
drop_probe team-a demo37-hijack-zoned

echo "  -- admission policy applied; re-try the zoned hijack (want refusal naming the hostname)"
k apply -f demos/37-two-gateways/50-hostname-policy.yaml >/dev/null
sleep 3
zoned_adm=$(k apply -f - <<'EOF' 2>&1 || true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo37-hijack-zoned, namespace: team-a}
spec:
  parentRefs: [{name: routes-gw, namespace: routes, sectionName: https-wildcard}]
  hostnames: ["shop.team-b.poc.local"]
  rules:
    - backendRefs: [{name: shop, port: 8080}]
EOF
)
echo "  admission: ${zoned_adm}"
drop_probe team-a demo37-hijack-zoned
echo "  ValidatingAdmissionPolicy httproute-own-zone left applied"

echo; echo "== 5. RBAC: the platform's Role vs edit-only"
cani() { # as ns resource — print can-i (exits 1 on "no"; keep the word, do not append another)
  local as=$1 ns=$2 res=$3 got
  got=$(k auth can-i create "$res" --as="$as" -n "$ns" 2>/dev/null || true)
  echo "  --as=$as create $res in $ns: ${got:-?}"
}
cani system:serviceaccount:team-b:team-b-dev team-b gateways
cani system:serviceaccount:team-b:team-b-dev team-b httproutes
cani system:serviceaccount:team-b:team-b-dev routes gateways
cani system:serviceaccount:team-b:team-b-dev routes httproutes
k -n team-b create sa team-b-edit-only --dry-run=client -o yaml 2>/dev/null | k apply -f - >/dev/null
k -n team-b create rolebinding team-b-edit-only --clusterrole=edit --serviceaccount=team-b:team-b-edit-only --dry-run=client -o yaml 2>/dev/null | k apply -f - >/dev/null
echo "  throwaway RoleBinding team-b-edit-only → ClusterRole edit (no gateway-owner):"
cani system:serviceaccount:team-b:team-b-edit-only team-b gateways
cani system:serviceaccount:team-b:team-b-edit-only team-b httproutes
k -n team-b delete rolebinding team-b-edit-only --ignore-not-found >/dev/null 2>&1 || true
k -n team-b delete sa team-b-edit-only --ignore-not-found >/dev/null 2>&1 || true
echo "  throwaway team-b-edit-only deleted"
