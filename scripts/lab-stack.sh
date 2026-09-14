#!/usr/bin/env bash
# lab-stack.sh — the observability stack on a complete, meshed lab, in dependency order, from the demos' own files
# (enhancement 004, phase 1). Every step is a chapter: it runs what that demo's README runs, with a deadline and the
# demo's own evidence line, and is idempotent (helm upgrade --install, kubectl apply).
#
#   scripts/lab-stack.sh all                         # everything below, in this order
#   scripts/lab-stack.sh routes monitoring …         # one or more steps
#
#   step            chapter     what it needs (must already exist)                                    what it gives
#   routes          demo 09     cert-manager + ClusterIssuer/ca-issuer (route A); the LB pools           routes-gw at 172.18.255.240, the wildcard
#                                                                                                       *.poc.local certificate, HTTPS for every app
#   monitoring      demo 16     the CNI; the Hubble metrics values need a Cilium restart (gotcha #42)     kube-prometheus-stack, Cilium + Hubble metrics,
#                                                                                                       the dashboards, Grafana at grafana.poc.local
#   tempo           demo 21     monitoring (the namespace, the Grafana data source)                     Tempo (traces) for the collectors
#   collectors      demos 10,   tempo; poc2 in the mesh (demo 22's tempo-central is a global Service)   the OTel collector per cluster: the Loki shipper
#                   22, 23                                                                              on poc1 (demo 25), traces from both clusters
#   loki-observer   demo 25     monitoring, routes, the mesh (one observer, both clusters), the relay   Loki, hubble-observer from the operator's fork
#                               on cert-manager's root (route A: demo 24)                               (cf2cnp + the verdicts dashboard as subcharts),
#                                                                                                       cf2cnp at cf2cnp.poc.local, the flows dashboard
#   obi             demo 18     collectors; monitoring's PodMonitor CRD on poc1                         OpenTelemetry eBPF Instrumentation, both clusters
#   hubble-cli      demo 25     cert-manager on poc1                                                    the operator certificate every demo script's
#                               Part 5e                                                                 `hubble observe` presents (scripts/hubble-tls.sh)
#
# Route A only: the relay's mTLS client certificate (demo 25), the CLI's certificate and the Gateway's wildcard are
# cert-manager Certificates from the enterprise root (demos 08 and 24). On route B (LAB_CERTMANAGER=0) the observer has
# no client certificate to present, and this script says so and stops.
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; C="${CTX#kind-}"; PEER_CTX="${LAB_STACK_PEER_CTX:-kind-poc2}"
KPS_VERSION="${KPS_VERSION:-90.1.1}"        # demo 16: kube-prometheus-stack (operator v0.93.1)
TEMPO_VERSION="${TEMPO_VERSION:-1.24.4}"    # demo 21
LOKI_VERSION="${LOKI_VERSION:-7.3.0}"       # demo 25
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
OBSERVER_BRANCH="${OBSERVER_BRANCH:-develop}"; OBSERVER_COMMIT="${OBSERVER_COMMIT:-}"   # demo 25 Part 10b: the fork's default branch
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }
k() { kubectl --context "$CTX" "$@"; }

need_route_a() {
  k get clusterissuer ca-issuer >/dev/null 2>&1 || die "$1 needs cert-manager's ClusterIssuer/ca-issuer (route A, demos 08/24): scripts/lab-up.sh without LAB_CERTMANAGER=0"
}
agents_after_upgrade() { # <cm resourceVersion before> <ds generation before> — the lab-up rule: restart only if cilium-config changed
  local cm_after gen_after
  cm_after=$(k -n kube-system get cm cilium-config -o jsonpath='{.metadata.resourceVersion}'); gen_after=$(k -n kube-system get ds cilium -o jsonpath='{.metadata.generation}')
  if [ "$gen_after" != "$2" ]; then echo "  agents: the DaemonSet template changed (generation $2 → $gen_after), Helm is rolling it"
  elif [ "$cm_after" != "$1" ]; then echo "  agents: cilium-config changed, restarting the DaemonSet to read it"; k -n kube-system rollout restart ds/cilium >/dev/null
  else echo "  agents: cilium-config and the DaemonSet unchanged, no restart"; fi
  k -n kube-system rollout status ds/cilium --timeout=8m >/dev/null
}

# ---------------------------------------------------------------- demo 09 — the Gateway every app lives behind
step_routes() {
  say "demo 09 — routes-gw (172.18.255.240), the wildcard certificate from ClusterIssuer/ca-issuer"
  need_route_a "demo 09's HTTPS listeners"
  # cert-manager watches Gateways only with this setting (demo 09 Part 2); --reuse-values keeps crds.enabled
  helm upgrade cert-manager jetstack/cert-manager -n cert-manager --kube-context "$CTX" --reuse-values --set config.gatewayAPI.enabled=true --wait --timeout 5m >/dev/null
  k apply -f demos/09-routes/01-gateway.yaml >/dev/null
  # cert-manager's gateway shim creates the Certificates from the listeners' hostnames a few seconds after the Gateway
  # exists; `kubectl wait` on an object that is not there yet fails at once (run 34887012554), so: exist first, then Ready
  local _i; for _i in $(seq 1 30); do k -n routes get certificate wildcard-poc-local-tls >/dev/null 2>&1 && break; sleep 4; done
  k -n routes get certificate wildcard-poc-local-tls >/dev/null 2>&1 || { k -n cert-manager logs deploy/cert-manager --tail=20; die "cert-manager created no Certificate for routes-gw's listeners in 2 minutes (demo 09 Part 2: config.gatewayAPI.enabled)"; }
  k -n routes wait certificate/wildcard-poc-local-tls --for=condition=Ready --timeout=3m >/dev/null
  local _i a=""; for _i in $(seq 1 30); do a=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null); [ -n "$a" ] && break; sleep 4; done
  [ "$a" = "172.18.255.240" ] || die "routes-gw got '${a:-no address}', the demo pins 172.18.255.240 (gotcha #13; is the pool applied?)"
  echo "routes-gw $a, certificate wildcard-poc-local-tls Ready"
}

# ---------------------------------------------------------------- demo 16 — kube-prometheus-stack, the Cilium and Hubble metrics, the dashboards
step_monitoring() {
  say "demo 16 — kube-prometheus-stack $KPS_VERSION on $C, Cilium + Hubble metrics, the dashboards, Grafana behind the Gateway"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  # the lab's values: the Prometheus liveness patch (gotcha #91), the Loki and Tempo data sources, the sidecar over ALL namespaces
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" -n monitoring --create-namespace \
    --kube-context "$CTX" -f demos/16-monitoring/values-kube-prometheus-stack.yaml --wait --timeout 15m >/dev/null \
    || { k -n monitoring get pods; die "kube-prometheus-stack did not become ready (demo 16)"; }
  # the Cilium side: agent/operator/envoy/hubble metrics with their ServiceMonitors and the chart's dashboards — an agent
  # port is added, so the DaemonSet rolls (gotcha #42: the Gateway is off the air for the rollout)
  local cm gen; cm=$(k -n kube-system get cm cilium-config -o jsonpath='{.metadata.resourceVersion}'); gen=$(k -n kube-system get ds cilium -o jsonpath='{.metadata.generation}')
  helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --kube-context "$CTX" --reuse-values -f demos/16-monitoring/values-cilium-metrics.yaml >/dev/null
  agents_after_upgrade "$cm" "$gen"
  k -n kube-system rollout status deploy/hubble-relay --timeout=5m >/dev/null
  k apply -f demos/16-monitoring/10-gateway.yaml >/dev/null   # grafana.poc.local on routes-gw
  local sm dash; sm=$(k get servicemonitor -A --no-headers 2>/dev/null | wc -l | tr -d ' '); dash=$(k get cm -A -l grafana_dashboard=1 --no-headers | wc -l | tr -d ' ')
  echo "ServiceMonitors: $sm; Grafana dashboards provisioned: $dash (Cilium's, Hubble's, the stack's)"
  local _i t=0; for _i in $(seq 1 24); do t=$(k get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/targets?state=active" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for x in d["data"]["activeTargets"] if x["health"]=="up"))' 2>/dev/null || echo 0); [ "${t:-0}" -ge 8 ] && break; sleep 10; done
  echo "Prometheus targets up: $t"
}

# ---------------------------------------------------------------- demo 21 — Tempo (single binary), the traces' store
step_tempo() {
  say "demo 21 — Tempo $TEMPO_VERSION in monitoring"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true; helm repo update grafana >/dev/null
  helm upgrade --install tempo grafana/tempo --version "$TEMPO_VERSION" -n monitoring --kube-context "$CTX" -f demos/21-tempo/values-tempo.yaml --wait --timeout 8m >/dev/null
  local _i r=""; for _i in $(seq 1 30); do r=$(k get --raw "/api/v1/namespaces/monitoring/services/tempo:3200/proxy/ready" 2>/dev/null || true); [ "$r" = "ready" ] && break; sleep 5; done
  echo "tempo /ready: ${r:-not ready after 150 s}"
}

# ---------------------------------------------------------------- demos 10, 22, 23 — the OTel collector per cluster
step_collectors() {
  say "demos 10 / 22 / 23 — the collector per cluster: $C's DaemonSet (traces to Tempo, the observer's flows to Loki), $PEER_CTX's gateway to tempo-central"
  k apply -f demos/10-tracing/otel-collector.yaml >/dev/null; k -n otel rollout restart ds/otel-collector >/dev/null
  k -n otel rollout status ds/otel-collector --timeout=5m >/dev/null
  k apply -f demos/23-collector-per-cluster/10-collector-service.yaml >/dev/null          # the per-cluster Service name apps rely on
  k apply -f demos/22-multicluster-observability/20-tempo-central-service.yaml >/dev/null  # the role-named global Service: poc1's Tempo for every cluster
  if kubectl --context "$PEER_CTX" get nodes >/dev/null 2>&1; then
    # a global Service is the same name in the same namespace in every cluster (demo 22): the peer has no monitoring
    # stack, so the namespace exists there only for this Service (run 34888325967: "namespaces monitoring not found")
    kubectl --context "$PEER_CTX" create namespace monitoring --dry-run=client -o yaml | kubectl --context "$PEER_CTX" apply -f - >/dev/null
    kubectl --context "$PEER_CTX" apply -f demos/22-multicluster-observability/20-tempo-central-service.yaml >/dev/null
    kubectl --context "$PEER_CTX" apply -f demos/23-collector-per-cluster/20-otel-collector-poc2.yaml >/dev/null
    kubectl --context "$PEER_CTX" -n otel rollout status deploy/otel-collector --timeout=5m >/dev/null   # demo 23: a Deployment, the cluster's gateway
    echo "$PEER_CTX: otel-collector up, exporting to tempo-central.monitoring (global, backends in $C)"
  fi
  echo "$C: otel-collector DaemonSet up ($(k -n otel get pods --no-headers | grep -c Running) pods)"
}

# ---------------------------------------------------------------- demo 25 — Loki, the observer from the fork, cf2cnp behind the Gateway, the flows dashboard
step_loki_observer() {
  say "demo 25 — Loki $LOKI_VERSION, hubble-observer from ephico2real2/hubble-observer@$OBSERVER_BRANCH (cf2cnp + the verdicts dashboard as its subcharts), cf2cnp.poc.local"
  need_route_a "demo 25's relay client certificate"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm upgrade --install loki grafana/loki --version "$LOKI_VERSION" -n monitoring --kube-context "$CTX" -f demos/25-hubble-observer-loki/values-loki.yaml --wait --timeout 8m >/dev/null
  k create namespace hubble-observer --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f demos/25-hubble-observer-loki/30-relay-mtls-client-cert.yaml >/dev/null            # Part 5: the relay requires mTLS
  k -n hubble-observer wait certificate/hubble-observer-relay-certs --for=condition=Ready --timeout=3m >/dev/null
  # the fork at its default branch: PR #9's policy, the field mask, the image at the agents' digest, the extended dashboard;
  # helm dependency build pulls cf2cnp and hubble-policy-verdicts from the forks' Helm repositories (Part 10b)
  demos/25-hubble-observer-loki/chart-from-fork.sh "$OBSERVER_BRANCH" $OBSERVER_COMMIT
  k -n hubble-observer rollout status deploy/hubble-observer --timeout=5m >/dev/null
  k apply -f demos/25-hubble-observer-loki/20-cf2cnp-route.yaml >/dev/null                       # cf2cnp.poc.local on routes-gw
  # the chart's own dashboard file, provisioned through the sidecar under the uid the demos link to (Part 10)
  demos/25-hubble-observer-loki/dashboard-from-file.sh .tmp/hubble-observer-fork/helm/hubble-observer/dashboard/cilium-hubble-flows.json \
    monitoring hubble-observer-flows hubble-observer-23862 Hubble | k apply -f - >/dev/null
  local _i; for _i in $(seq 1 24); do k -n routes get httproute cf2cnp -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True && break; sleep 5; done
  echo "observer: $(k -n hubble-observer get deploy hubble-observer -o jsonpath='{.status.readyReplicas}')/1 ready; cf2cnp route: $(k -n routes get httproute cf2cnp -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null); Loki: $(k -n monitoring get sts loki -o jsonpath='{.status.readyReplicas}')/1"
  # this lab's root, for the check's curl (the file in docs/ is the laptop's root)
  mkdir -p .tmp; k -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > .tmp/root-ca.crt
  echo "the demo's own check (demos/25-hubble-observer-loki/check.sh 1):"
  ROOT_CA=.tmp/root-ca.crt demos/25-hubble-observer-loki/check.sh 1 2>&1 | sed 's/^/  /' | head -40 || true
}

# ---------------------------------------------------------------- demo 18 — OBI on both clusters
step_obi() {
  say "demo 18 — OpenTelemetry eBPF Instrumentation on $C and $PEER_CTX"
  k apply -f demos/18-obi/20-collector-service.yaml >/dev/null 2>&1 || true   # superseded by demo 23's per-cluster Service; apply keeps the namespace
  demos/18-obi/deploy.sh "$C"
  if kubectl --context "$PEER_CTX" get nodes >/dev/null 2>&1; then demos/18-obi/deploy.sh "${PEER_CTX#kind-}"; fi
  demos/18-obi/check.sh 2>&1 | sed 's/^/  /' | head -20 || true
}

# ---------------------------------------------------------------- demo 25 Part 5e — the CLI's own certificate
step_hubble_cli() {
  say "demo 25 Part 5e — the operator certificate the demo scripts' hubble CLI presents (scripts/hubble-tls.sh)"
  need_route_a "the hubble CLI's client certificate"
  k apply -f demos/25-hubble-observer-loki/40-hubble-cli-client-cert.yaml >/dev/null
  k -n kube-system wait certificate/hubble-cli-client-certs --for=condition=Ready --timeout=3m >/dev/null
  if command -v hubble >/dev/null; then
    # shellcheck disable=SC2046
    scripts/hubble-tls.sh --configure "$CTX" >/dev/null && echo "hubble CLI configured for $CTX: $(hubble status -P --kube-context "$CTX" $(scripts/hubble-tls.sh "$CTX") 2>&1 | grep -E 'Current/Max Flows|Nodes|rror' | tr '\n' ' ')"
  else echo "::warning::no hubble CLI on this host — the demo scripts that call it (26's verify.sh, 32's callers.sh) need it"; fi
}

[ $# -ge 1 ] || { echo "usage: $0 all | routes monitoring tempo collectors loki-observer obi hubble-cli"; exit 2; }
[ "$1" = all ] && set -- routes monitoring tempo collectors loki-observer obi hubble-cli
for s in "$@"; do
  case "$s" in
    routes) step_routes;; monitoring) step_monitoring;; tempo) step_tempo;; collectors) step_collectors;;
    loki-observer) step_loki_observer;; obi) step_obi;; hubble-cli) step_hubble_cli;;
    *) die "unknown step $s";;
  esac
done
say "stack up on $C: $*"
