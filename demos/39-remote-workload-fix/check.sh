#!/usr/bin/env bash
# check.sh — demo 39's measurement of cilium/cilium#25676: does Hubble name the workload of a
# backend pod on ANOTHER node, on the Envoy-reported (Gateway) HTTP flow?
# The reporting agent is the one on the client's node (demos 37 and 39). Read its :9965 metrics
# from the host (node InternalIP is reachable on the Mac and on a GitHub runner).
#
#   demos/39-remote-workload-fix/check.sh [context]
#   NS=team-a APP=shop HOST=shop-a.poc.local GATEWAY=routes/routes-gw REQUESTS=40
#   KEEP=1 keeps the probe pod. Exit = number of FAIL rows.
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${1:-${CTX:-kind-poc1}}"
NS="${NS:-team-a}"
APP="${APP:-shop}"
HOST="${HOST:-shop-a.poc.local}"
GATEWAY="${GATEWAY:-routes/routes-gw}"
REQUESTS="${REQUESTS:-40}"
KEEP="${KEEP:-0}"
CA="${ROOT_CA:-.tmp/root-ca.crt}"
GW_NS="${GATEWAY%%/*}"
GW_NAME="${GATEWAY##*/}"
k() { kubectl --context "$CTX" "$@"; }
fails=0
row() { # ok|fail|warn  what  measured  rule  — prints PASS/FAIL/WARN; fail increments the exit count
  local st
  case "$1" in
    ok)   st=PASS ;;
    fail) st=FAIL; fails=$((fails + 1)) ;;
    warn) st=WARN ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-70s %-52s %s\n' "$st" "$2" "$3" "$4"
}

printf '\n== demo 39 — Hubble names a remote backend'\''s workload (Envoy-reported Gateway flows)\n'
printf '   context=%s ns=%s app=%s host=%s gateway=%s requests=%s\n' "$CTX" "$NS" "$APP" "$HOST" "$GATEWAY" "$REQUESTS"
printf '   CA=%s (probe curls use -sk; names are --resolve'\''d — the runner has no /etc/hosts)\n' "$CA"

# ---------------------------------------------------------------- 1. the backend
echo "== 1. the backend"
sel="app=$APP"
pods=$(k -n "$NS" get pods -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
if [ -z "${pods:-}" ]; then
  sel="app.kubernetes.io/name=$APP"
  pods=$(k -n "$NS" get pods -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
fi
echo "  selector: $sel"
k -n "$NS" get pods -l "$sel" -o wide 2>/dev/null | sed 's/^/  /' || echo "  (kubectl get pods failed)"
backend_pod=; backend_ip=; backend_node=
# first Running pod with an IP and a node
while IFS=$'\t' read -r p ip node phase; do
  [ -z "${p:-}" ] && continue
  [ "${phase:-}" = Running ] || continue
  [ -n "${ip:-}" ] && [ -n "${node:-}" ] || continue
  backend_pod=$p; backend_ip=$ip; backend_node=$node
  break
done <<EOF
$pods
EOF
if [ -z "${backend_pod:-}" ]; then
  echo "  backend: none (no Running pod labelled $sel in $NS)"
  row fail "The reporting agent is on a different node than the backend" "no backend pod" "need a Running pod labelled app=$APP (or app.kubernetes.io/name) in $NS"
  row fail "Gateway requests reached the backend" "not attempted" "no backend"
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "not attempted" "no backend"
  exit "$fails"
fi
echo "  backend: $backend_pod on $backend_node ($backend_ip)"

# ---------------------------------------------------------------- 2. the other node
echo "== 2. the other node"
other_node=
while IFS=$'\t' read -r name ready; do
  [ -z "${name:-}" ] && continue
  [ "${ready:-}" = True ] || continue
  [ "$name" != "$backend_node" ] || continue
  other_node=$name
  break
done <<EOF
$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || true)
EOF
if [ -z "${other_node:-}" ]; then
  echo "  other node: none (single Ready node, or kubectl failed)"
  row warn "The reporting agent is on a different node than the backend" "one node — the remote case cannot be built here" "need ≥ 2 Ready nodes; backend is on $backend_node"
  exit 0
fi
other_ip=$(k get node "$other_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
echo "  other node: $other_node (${other_ip:-no InternalIP})"

# ---------------------------------------------------------------- 3. the client on the other node
echo "== 3. the client on the other node"
PROBE_NS=default
PROBE=hubble-workload-probe
cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then
    k -n "$PROBE_NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
exist_node=$(k -n "$PROBE_NS" get pod "$PROBE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
exist_phase=$(k -n "$PROBE_NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ -n "${exist_node:-}" ] && { [ "$exist_node" != "$other_node" ] || [ "${exist_phase:-}" != Running ]; }; then
  echo "  replacing leftover probe (node=${exist_node:-?} phase=${exist_phase:-?})"
  k -n "$PROBE_NS" delete pod "$PROBE" --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1 || true
fi
if ! k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE
  namespace: $PROBE_NS
  labels:
    app: hubble-workload-probe
spec:
  nodeName: $other_node
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "600"]
EOF
then
  echo "  probe: kubectl apply failed"
  row fail "The reporting agent is on a different node than the backend" "probe apply failed" "client on $other_node, backend on $backend_node"
  row fail "Gateway requests reached the backend" "not attempted" "probe missing"
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "not attempted" "probe missing"
  exit "$fails"
fi
if ! k -n "$PROBE_NS" wait --for=condition=Ready "pod/$PROBE" --timeout=90s >/dev/null 2>&1; then
  phase=$(k -n "$PROBE_NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '?')
  msg=$(k -n "$PROBE_NS" get pod "$PROBE" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true)
  echo "  probe: not Ready in 90s (phase=${phase:-?} ${msg:-})"
  row fail "The reporting agent is on a different node than the backend" "probe not Ready (phase=${phase:-?})" "client wanted on $other_node, backend on $backend_node"
  row fail "Gateway requests reached the backend" "not attempted" "probe not Ready"
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "not attempted" "probe not Ready"
  exit "$fails"
fi
probe_node=$(k -n "$PROBE_NS" get pod "$PROBE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
echo "  probe: $PROBE_NS/$PROBE Ready on ${probe_node:-?} (image curlimages/curl:8.10.1, sleep 600)"

# ---------------------------------------------------------------- 4. the Gateway address, then REQUESTS from the probe
echo "== 4. the Gateway address"
gw_addr=$(k -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
echo "  gateway: $GW_NS/$GW_NAME address=${gw_addr:-?}"
ok200=0
if [ -z "${gw_addr:-}" ]; then
  echo "  requests: not attempted (no Gateway address)"
else
  # one exec, a /bin/sh loop: Alpine has no bash; --resolve so the runner (and the pod) need no hosts file
  ok200=$(k -n "$PROBE_NS" exec "$PROBE" -- sh -c "
ok=0
i=0
while [ \$i -lt $REQUESTS ]; do
  code=\$(curl -sk -o /dev/null -w '%{http_code}' --resolve ${HOST}:443:${gw_addr} --connect-timeout 5 --max-time 10 https://${HOST}/ || echo 000)
  [ \"\$code\" = 200 ] && ok=\$((ok + 1))
  i=\$((i + 1))
done
echo \$ok
" 2>/dev/null || echo 0)
  echo "  requests: ${ok200}/$REQUESTS returned 200 (curl -sk --resolve $HOST:443:$gw_addr https://$HOST/ × $REQUESTS from the probe)"
  sleep 2
fi

# ---------------------------------------------------------------- 5. the REPORTING agent's Hubble metrics (the other node's :9965)
echo "== 5. the reporting agent's Hubble metrics"
ds_image=$(k -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')
agent_pod=$(k -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$other_node" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
agent_ver=
if [ -n "${agent_pod:-}" ]; then
  agent_ver=$(k -n kube-system exec "$agent_pod" -c cilium-agent -- cilium-agent --version 2>/dev/null || true)
fi
echo "  agent image (DaemonSet): ${ds_image}"
echo "  reporting agent: ${agent_pod:-?} on $other_node  ${agent_ver:-"(cilium-agent --version not read)"}"

metrics=; curl_err=
if [ -z "${other_ip:-}" ]; then
  curl_err="no InternalIP on $other_node"
  echo "  metrics: $curl_err"
else
  echo "  GET http://$other_ip:9965/metrics"
  metrics=$(curl -sS --connect-timeout 5 --max-time 15 "http://${other_ip}:9965/metrics" 2>/tmp/demo39-metrics.err || true)
  curl_err=$(cat /tmp/demo39-metrics.err 2>/dev/null || true)
  rm -f /tmp/demo39-metrics.err
fi

# parse hubble_http_requests_total{...} with destination_namespace=$NS and source=reserved:ingress
# TSV: destination_app  destination_workload  reporter  value
series=
if [ -n "${metrics:-}" ]; then
  series=$(printf '%s\n' "$metrics" | jq -R -r --arg ns "$NS" '
    select(test("^hubble_http_requests_total\\{"))
    | capture("^hubble_http_requests_total\\{(?<labels>[^}]*)\\}[ \t]+(?<value>[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?)")
    | . as $m
    | (($m.labels | [scan("([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"")] | map({key: .[0], value: .[1]}) | from_entries) // {}) as $l
    | select(($l.destination_namespace // "") == $ns and ($l.source // "") == "reserved:ingress")
    | [
        (if ($l.destination_app // "") == "" then "-" else $l.destination_app end),
        ($l.destination_workload // ""),
        (if ($l.reporter // "") == "" then "-" else $l.reporter end),
        $m.value
      ]
    | @tsv
  ' 2>/tmp/demo39-jq.err || true)
  jq_err=$(cat /tmp/demo39-jq.err 2>/dev/null || true)
  rm -f /tmp/demo39-jq.err
  [ -n "${jq_err:-}" ] && echo "  jq: $jq_err"
else
  [ -n "${curl_err:-}" ] && echo "  curl: $curl_err"
fi

n_series=0
named=0
empty=0
other_wl=
if [ -n "${series:-}" ]; then
  echo "  matching hubble_http_requests_total (destination_namespace=\"$NS\" source=\"reserved:ingress\"):"
  while IFS=$'\t' read -r dapp dwl reporter count; do
    [ -z "${dapp:-}" ] && continue
    n_series=$((n_series + 1))
    echo "  $NS/$dapp destination_workload=[${dwl}] reporter=${reporter} count=${count}"
    if [ -n "${dwl:-}" ] && [ "$dwl" = "$APP" ]; then
      named=$((named + 1))
    elif [ -z "${dwl:-}" ]; then
      empty=$((empty + 1))
    else
      other_wl=${other_wl:+$other_wl,}$dwl
    fi
  done <<EOF
$series
EOF
else
  echo "  matching hubble_http_requests_total: none"
fi

# ---------------------------------------------------------------- rows A B C
printf '\n  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE
if [ "${probe_node:-}" = "$other_node" ] && [ "$other_node" != "$backend_node" ]; then
  row ok "The reporting agent is on a different node than the backend" "client on $other_node, backend on $backend_node" "probe nodeName is a Ready node other than the backend's"
else
  row fail "The reporting agent is on a different node than the backend" "client on ${probe_node:-?}, backend on $backend_node" "probe must run on $other_node, not on the backend's node"
fi

need90=$((REQUESTS * 90 / 100))
if [ "${ok200:-0}" -eq "$REQUESTS" ]; then
  row ok "Gateway requests reached the backend" "${ok200}/$REQUESTS HTTP 200" "equals REQUESTS ($REQUESTS)"
elif [ "${ok200:-0}" -ge "$need90" ]; then
  row ok "Gateway requests reached the backend" "${ok200}/$REQUESTS HTTP 200" "≥ 90% of REQUESTS (${need90}/$REQUESTS)"
else
  row fail "Gateway requests reached the backend" "${ok200}/$REQUESTS HTTP 200" "want $REQUESTS 200s (or ≥ 90% = $need90) through $HOST @$gw_addr"
fi

if [ "$named" -gt 0 ]; then
  row ok "Hubble names the remote backend's workload on the Envoy-reported flow" "destination_workload=\"$APP\" ($named series)" "non-empty and equal to APP on the other node's agent (patched: \"$APP\"; 1.20.2: \"\")"
elif [ "$empty" -gt 0 ]; then
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "destination_workload=\"\" ($empty series)" "cilium/cilium#25676 on release 1.20.2; want \"$APP\" — agent ${ds_image}"
elif [ -n "${other_wl:-}" ]; then
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "destination_workload=[${other_wl}] (not \"$APP\")" "want destination_workload=\"$APP\" — agent ${ds_image}"
else
  why="no series"
  [ -n "${curl_err:-}" ] && why="no series ($curl_err)"
  [ -z "${metrics:-}" ] && [ -z "${curl_err:-}" ] && why="no series (empty metrics body)"
  row fail "Hubble names the remote backend's workload on the Envoy-reported flow" "$why" "want hubble_http_requests_total destination_namespace=\"$NS\" source=\"reserved:ingress\" — agent ${ds_image}"
fi

# ---------------------------------------------------------------- 6. which build produced the result (also printed in §5)
echo "== 6. the agents' image"
echo "  DaemonSet cilium image: ${ds_image}"
echo "  $other_node agent (${agent_pod:-?}): ${agent_ver:-"(cilium-agent --version not read)"}"
[ "${KEEP:-0}" = 1 ] && echo "  probe: kept (KEEP=1)"

exit "$fails"
