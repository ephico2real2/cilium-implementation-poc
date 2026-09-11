#!/usr/bin/env bash
# churn-decompose.sh — where does the per-connection cost sit? The same fortio load (64 parallel,
# Connection: close, 8 s) against three targets that differ by exactly one thing each:
#   pod-ip     the backend pod directly          -> no service translation, no DNS
#   clusterip  the Service's ClusterIP           -> + service translation (iptables DNAT / eBPF)
#   dns-name   the Service's DNS name            -> + a DNS lookup per connection
# Prints qps, p50/p99 latency, and the datapath daemon's CPU on the backend node. Bash on purpose:
# `set -- $t` does not word-split under zsh (gotcha #29) and an earlier inline version measured nothing.
#
# Usage:  scripts/churn-decompose.sh <cluster> [label]
set -uo pipefail
C="${1:?usage: churn-decompose.sh <cluster> [label]}"; L="${2:-}"; CTX="kind-$C"; NS=forensic; W="$C-worker"
k() { kubectl --context "$CTX" "$@"; }
POD_IP=$(k -n $NS get pod -l app=web -o jsonpath='{.items[0].status.podIP}'); SVC_IP=$(k -n $NS get svc web -o jsonpath='{.spec.clusterIP}')
if k -n kube-system get ds cilium >/dev/null 2>&1; then DAEMON=cilium-agent; else DAEMON=kube-proxy; fi
echo "=== churn decomposition on $C ${L:+($L)} — 64 conns, Connection: close, 8 s each; daemon=$DAEMON on $W ==="
echo "  VM load: $(docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -- cut -d' ' -f1-3 /proc/loadavg)"
printf '  %-10s %-44s %8s %9s %9s %s\n' target url qps p50_ms p99_ms "$DAEMON%"
run() { # $1 label, $2 url
  local out cpu; out=$(k -n $NS exec fortio -- fortio load -c 64 -qps 0 -t 8s -H 'Connection: close' -quiet "$2" 2>&1)
  cpu=$(docker exec "$W" top -b -n1 -w 200 | awk -v d="$DAEMON" '$0 ~ d {s+=$9} END{print s+0}')
  echo "$out" | awk -v l="$1" -v u="$2" -v c="$cpu" '/# target 50%/{p50=$4*1000} /# target 99%/{p99=$4*1000} /All done/{q=$(NF-1)} END{printf "  %-10s %-44s %8s %9.1f %9.1f %s\n", l, u, q, p50, p99, c}'
}
run pod-ip    "http://$POD_IP:8080/"
run clusterip "http://$SVC_IP/"
run dns-name  "http://web.$NS.svc.cluster.local/"
