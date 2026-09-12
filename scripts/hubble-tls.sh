#!/usr/bin/env bash
# hubble-tls.sh <kube-context> — since demo 25 Part 5 the relays speak TLS and require a client certificate (mTLS).
# Fetches the operator client certificate (demos/25-hubble-observer-loki/40-hubble-cli-client-cert.yaml) and the root
# from the cluster into .tmp/hubble-tls/<context>/ (git-ignored, mode 0600) and prints the hubble CLI flags to use:
#   hubble status -P --kube-context kind-poc1 $(scripts/hubble-tls.sh kind-poc1)
# --tls-server-name: the relay's certificate is *.hubble-relay.cilium.io (Cilium issues it so); any name under it verifies.
set -euo pipefail; CTX="${1:?kube-context}"; cd "$(dirname "$0")/.."
DIR=".tmp/hubble-tls/$CTX"; mkdir -p "$DIR"; chmod 700 "$DIR"
for k in ca.crt tls.crt tls.key; do kubectl --context "$CTX" -n kube-system get secret hubble-cli-client-certs -o jsonpath="{.data.$(echo $k | sed 's/\./\\./')}" | base64 -d > "$DIR/$k"; chmod 600 "$DIR/$k"; done
echo "--tls --tls-server-name cli.hubble-relay.cilium.io --tls-ca-cert-files $DIR/ca.crt --tls-client-cert-file $DIR/tls.crt --tls-client-key-file $DIR/tls.key"
