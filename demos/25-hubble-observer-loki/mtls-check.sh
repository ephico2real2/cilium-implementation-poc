#!/usr/bin/env bash
# mtls-check.sh — Part 5 as a check: the relay requires mutual TLS, the observer holds a client certificate from the
# enterprise issuer and streams over it, an anonymous client is refused. Five measured lines, the way the maintainer of
# hubble-observer asked for a verification of 2.6.0's TLS/mTLS support (onzack/hubble-observer#6) — run by the CI lab's
# report on every run, and by hand:
#   demos/25-hubble-observer-loki/mtls-check.sh
# Evidence printer: exits 0; the words that mean trouble are for the reader (and the report's count).
set -uo pipefail; cd "$(dirname "$0")/../.."; CTX="${LAB_STACK_CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }

echo "== 1. the relay: server TLS on, client certificates required (hubble-relay-config, the Service port)"
cfg=$(k -n kube-system get cm hubble-relay-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
printf '  %-28s %s\n' "tls-relay-server-cert-file" "$(printf '%s\n' "$cfg" | grep -c 'tls-relay-server-cert-file')" \
                     "tls-relay-client-ca-files" "$(printf '%s\n' "$cfg" | grep -c 'tls-relay-client-ca-files')" \
                     "disable-server-tls" "$(printf '%s\n' "$cfg" | grep -c 'disable-server-tls: true') (0 = TLS on)"
printf '  %-28s %s\n' "Service hubble-relay port" "$(k -n kube-system get svc hubble-relay -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
printf '  %-28s %s\n' "relay's certificate" "$(k -n kube-system get secret hubble-relay-server-certs -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -subject -issuer 2>/dev/null | tr '\n' ' ')"

echo "== 2. the observer's client certificate: from the enterprise issuer, client auth, Ready (30-relay-mtls-client-cert.yaml)"
printf '  %-28s %s\n' "Certificate Ready" "$(k -n hubble-observer get certificate hubble-observer-relay-certs -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
printf '  %-28s %s\n' "issued" "$(k -n hubble-observer get secret hubble-observer-relay-certs -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -subject -issuer -ext extendedKeyUsage 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
printf '  %-28s %s\n' "the pod's environment" "$(k -n hubble-observer get deploy hubble-observer -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value} {end}' 2>/dev/null | tr ' ' '\n' | grep '^HUBBLE_TLS' | tr '\n' ' ')"

echo "== 3. the observer over mTLS: the relay as the observer sees it (hubble status from inside the pod)"
printf '  %s\n' "$(k -n hubble-observer exec deploy/hubble-observer -c hubble-observer -- hubble status --server hubble-relay.kube-system.svc.cluster.local:443 2>&1 | grep -E 'Healthcheck|Connected Nodes' | tr '\n' ' ')"
printf '  %-28s %s\n' "pod" "$(k -n hubble-observer get pods -l app.kubernetes.io/name=hubble-observer -o jsonpath='{range .items[*]}{.metadata.name} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | head -2 | tr '\n' ' ')"

echo "== 4. an anonymous client is refused (GUIDE exercise 7): the agent image's own hubble CLI, no certificate"
k -n default delete pod anyone --ignore-not-found --wait=true >/dev/null 2>&1
k -n default run anyone --image="quay.io/cilium/cilium:v${CILIUM_VERSION:-1.20.2}" --restart=Never --command -- sleep 300 >/dev/null 2>&1
k -n default wait --for=condition=Ready pod/anyone --timeout=2m >/dev/null 2>&1 || echo "  (the anonymous pod did not become Ready)"
# the refusal is the result: the relay's sentence is printed on its own, not the client's whole error line (run 34980519349's
# report counted those "error" words as trouble; a refusal is what this part expects)
a=$(k -n default exec anyone -- hubble status --server hubble-relay.kube-system.svc.cluster.local:443 --tls --tls-allow-insecure 2>&1 | tr '\n' ' ')
case "$a" in *"certificate required"*) printf '  %-28s %s\n' "TLS, no client certificate" "refused — the relay answered: tls: certificate required";;
  *"Connected Nodes"*) printf '  %-28s %s\n' "TLS, no client certificate" "ACCEPTED (the relay does not require client certificates): $(printf '%s' "$a" | grep -oE 'Connected Nodes: [0-9/]+')";;
  *) printf '  %-28s %s\n' "TLS, no client certificate" "no verdict: $(printf '%s' "$a" | cut -c1-120)";; esac
b=$(k -n default exec anyone -- hubble status --server hubble-relay.kube-system.svc.cluster.local:443 2>&1 | tr '\n' ' ')
case "$b" in *"Connected Nodes"*) printf '  %-28s %s\n' "plaintext" "ACCEPTED in plaintext: $(printf '%s' "$b" | grep -oE 'Connected Nodes: [0-9/]+')";;
  *"server preface"*|*"connection error"*) printf '  %-28s %s\n' "plaintext" "refused — no server preface in plaintext (the relay speaks TLS only)";;
  *) printf '  %-28s %s\n' "plaintext" "no verdict: $(printf '%s' "$b" | cut -c1-120)";; esac
k -n default delete pod anyone --wait=false >/dev/null 2>&1

echo "== 5. what came through the mTLS stream: the observer's stdout and Loki, last 15 minutes"
printf '  %-28s %s\n' "observer stdout lines" "$(k -n hubble-observer logs deploy/hubble-observer -c hubble-observer --since=15m 2>/dev/null | grep -c '"flow"')"
NOW=$(date +%s)
printf '  %-28s %s\n' "Loki lines" "$(k get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query?query=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("sum(count_over_time({namespace=\"hubble-observer\",container=\"hubble-observer\"}[15m]))"))')&time=$NOW" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)"
