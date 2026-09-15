#!/usr/bin/env bash
# check.sh — demo 36's proofs, in the order of the design: the chain (which CA signed the wildcard), the host (its trust
# store verifies the root and a curl by name with NO --cacert verifies the Gateway), the clusters (trust-manager's Bundle
# Synced, the ConfigMap in every namespace of both clusters, one fingerprint), and a pod (the forensic client with the
# bundle mounted: a curl with the mounted root answers, the same curl without it is refused). Evidence printer: it
# exits 0 by design and says on every line what it saw; the words that mean trouble are the report's to count.
#   demos/36-trust-everywhere/check.sh
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; PEER="${LAB_STACK_PEER_CTX:-kind-poc2}"
k() { kubectl --context "$CTX" "$@"; }
GW=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

echo "== 1. the chain: the issuer, its CA, the wildcard it signed"
echo "  ClusterIssuer/ca-issuer signs with Secret: $(k get clusterissuer ca-issuer -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || echo '?')"
echo "  that Secret's certificate: $(k -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -subject -fingerprint -sha256 2>/dev/null | tr '\n' ' ')"
echo "  the wildcard: $(k -n routes get secret wildcard-poc-local-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -issuer -subject -ext subjectAltName 2>/dev/null | tr '\n' ' ' | cut -c1-200)"

echo; echo "== 2. this host: its trust store, then the Gateway by name with no --cacert"
scripts/lab-trust.sh verify "$CTX" 2>&1 || true
[ -n "$GW" ] && { scripts/lab-trust.sh prove "$GW" 2>&1 || true; } || echo "  no routes-gw address (scripts/lab-stack.sh routes)"

echo; echo "== 3. the clusters: trust-manager's Bundle, the ConfigMap in every namespace, one fingerprint everywhere"
for c in "$CTX" "$PEER"; do
  kubectl --context "$c" get nodes >/dev/null 2>&1 || { echo "  $c: not reachable"; continue; }
  synced=$(kubectl --context "$c" get bundle enterprise-root -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "?")
  cms=$(kubectl --context "$c" get cm -A --field-selector metadata.name=enterprise-root -o json 2>/dev/null)
  n=$(printf '%s' "$cms" | jq '.items | length' 2>/dev/null || echo 0); nss=$(kubectl --context "$c" get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
  fps=$(printf '%s' "$cms" | jq -r '.items[].data["ca.crt"] | @base64' 2>/dev/null | while read -r b; do printf '%s' "$b" | base64 -d | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; done | sort -u | wc -l | tr -d ' ')
  echo "  $c: Bundle enterprise-root Synced=$synced; ConfigMap enterprise-root in $n of $nss namespaces; distinct fingerprints: $fps"
done

echo; echo "== 4. a pod with the bundle mounted (forensic/client, demo 11's rig): the Gateway with the mounted root, and without"
if k -n forensic get pod client >/dev/null 2>&1 && [ -n "$GW" ]; then
  echo "  mounted: $(k -n forensic exec client -- sh -c 'ls -l /etc/enterprise-root/ 2>/dev/null | tail -1; openssl x509 -in /etc/enterprise-root/ca.crt -noout -subject 2>/dev/null' 2>/dev/null | tr '\n' ' ')"
  for host in bank.poc.local grafana.poc.local; do scripts/lab-trust.sh pod-check "$CTX" forensic client "$GW" "$host" 2>&1 || true; done
else echo "  no forensic/client pod (scripts/lab-apps.sh forensic) or no Gateway address — the pod part not measured"; fi
