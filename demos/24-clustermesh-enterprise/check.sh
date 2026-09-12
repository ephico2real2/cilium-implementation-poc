#!/usr/bin/env bash
# check.sh — the enterprise-CA state of the mesh, both clusters: one root, every leaf (mesh AND Hubble) issued by
# cert-manager from it, and Hubble Relay on poc1 connected to every node of both clusters.
set -uo pipefail
for C in poc1 poc2; do
  echo "== $C =="
  echo "  ClusterIssuer ca-issuer ready=$(kubectl --context kind-$C get clusterissuer ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')  root sha256 $(kubectl --context kind-$C -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)…"
  kubectl --context kind-$C -n kube-system get certificates -o custom-columns='  CERT:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ISSUER:.spec.issuerRef.name,RENEWS:.status.renewalTime' --no-headers | sed 's/^/  /'
  for s in clustermesh-apiserver-server-cert hubble-server-certs hubble-relay-client-certs; do
    echo "  $s signed by: $(kubectl --context kind-$C -n kube-system get secret $s -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer | sed 's/issuer=//')"
  done
done
echo "== Hubble Relay on poc1 =="
kubectl --context kind-poc1 -n kube-system port-forward svc/hubble-relay 4245:80 >/dev/null 2>&1 & PF=$!; sleep 3
hubble status --server localhost:4245 2>/dev/null | grep -E "Connected Nodes|Unavailable" | sed 's/^/  /'
hubble list nodes --server localhost:4245 2>/dev/null | grep -v "^time=" | awk 'NR>1{print "  "$1, $2}'
kill $PF 2>/dev/null
echo "== mesh =="
cilium clustermesh status --context kind-poc1 2>&1 | grep -E "^  - poc2" | sed 's/^/  poc1 → /'
cilium clustermesh status --context kind-poc2 2>&1 | grep -E "^  - poc1" | sed 's/^/  poc2 → /'
