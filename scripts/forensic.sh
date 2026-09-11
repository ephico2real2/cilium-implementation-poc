#!/usr/bin/env bash
# forensic.sh — the SAME measurements on a kube-proxy/iptables cluster and on a Cilium cluster,
# so every "Cilium is faster/leaner" claim is a number next to a number from one machine.
#
# Usage:   scripts/forensic.sh <cluster>            # poc3 (kindnet + kube-proxy iptables) or poc1 (Cilium, no kube-proxy)
#          SCALES="100 500 1000" scripts/forensic.sh poc3
# Needs:   demos/11-kube-proxy-vs-cilium/00-rig.yaml applied and Ready in namespace `forensic`.
# Prints:  everything, raw. Nothing is computed off-screen; medians are printed next to their samples.
#
# The five measurements, and what each one is allowed to conclude:
#   1. RULE COUNT vs SERVICES  — how much datapath state one Service costs (iptables rules vs eBPF map entries)
#   2. PROGRAMMING LATENCY     — ms from `kubectl create service` to the first successful connection, at each scale
#   3. THROUGHPUT              — iperf3 worker->worker2, pod IP and via the Service (5 runs each, median + spread)
#   4. CONNECTION CHURN        — fortio, Connection: close, 64 parallel: qps, latency percentiles
#   5. CONNTRACK + CPU         — what the node pays during (4): conntrack entries, node CPU%, the datapath daemon's CPU%
set -uo pipefail
C="${1:?usage: forensic.sh <cluster>}"; CTX="kind-$C"; NS=forensic
W="$C-worker"; W2="$C-worker2"                      # backends + iperf3 server on W; client + fortio on W2
SCALES="${SCALES:-100 500 1000}"; RUNS="${RUNS:-5}"
k() { kubectl --context "$CTX" "$@"; }
kn() { k -n "$NS" "$@"; }
hdr() { echo; echo "================================================================================"; echo " $*"; echo "================================================================================"; }
node() { docker exec "$1" sh -c "$2" 2>/dev/null; }       # run a command inside a kind node
# kube-proxy metrics, read from the node without curl: bash /dev/tcp to the metrics port.
kp_metrics() { docker exec "$1" bash -c 'exec 3<>/dev/tcp/127.0.0.1/10249; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3' 2>/dev/null; }
kp_metric() { kp_metrics "$1" | awk -v m="$2" '$1 ~ "^"m"[{ ]" || $1 == m {print $2; exit}'; }
CILIUM=0; k -n kube-system get ds cilium >/dev/null 2>&1 && CILIUM=1
cilium_pod() { k -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$1" -o jsonpath='{.items[0].metadata.name}'; }
cilium_exec() { local p; p=$(cilium_pod "$1"); shift; k -n kube-system exec "$p" -c cilium-agent -- "$@" 2>/dev/null; }
loadavg() { docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -- cut -d' ' -f1-3 /proc/loadavg 2>/dev/null; }
# Mac<->VM clock skew, ms, from the sample with the smallest round trip (the VM is the pods' clock).
skew_ms() { python3 - "$W2" <<'PY'
import subprocess, time
best = None
for _ in range(7):
    a = time.time(); vm = float(subprocess.check_output(['docker','exec',__import__('sys').argv[1],'date','+%s.%N']).decode()); b = time.time()
    rtt = b - a; s = vm - (a + b) / 2
    if best is None or rtt < best[0]: best = (rtt, s)
print(f"{best[1]*1000:.1f} {best[0]*1000:.1f}")
PY
}

hdr "0. IDENTITY — $C  ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
k get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,KERNEL:.status.nodeInfo.kernelVersion' --no-headers | sed 's/^/  /'
if [ $CILIUM = 1 ]; then
  echo "  datapath : Cilium $(k -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://; s/@.*//'), kube-proxy DaemonSet: $(k -n kube-system get ds kube-proxy --no-headers 2>&1 | grep -c kube-proxy) (0 = none)"
  echo "  KPR      : $(cilium_exec "$W" cilium-dbg status | grep -E '^KubeProxyReplacement' | tr -s ' ')"
else
  echo "  datapath : kindnet $(k -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://'), kube-proxy $(k -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://') mode=$(k -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '/^mode:/{print $2}')"
fi
echo "  rig      :"; kn get pods -o custom-columns='  POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,READY:.status.containerStatuses[0].ready' --no-headers | sed 's/^/  /'
echo "  VM load  : $(loadavg)"
read -r SKEW RTT <<<"$(skew_ms)"; echo "  clock    : VM is ${SKEW} ms ahead of the Mac (measured, best of 7, rtt ${RTT} ms) — subtracted from every latency below"
CLIENT_IP=$(kn get pod client -o jsonpath='{.status.podIP}'); SERVER_IP=$(kn get pod iperf3-server -o jsonpath='{.status.podIP}')
SVC_CIDR=$(k -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | awk '/serviceSubnet/{print $2}')
SVC_PREFIX=$(echo "$SVC_CIDR" | cut -d. -f1-2)       # e.g. 10.31 — pre-chosen ClusterIPs live in <prefix>.250.x

# ---------- state readers: identical shape on both clusters --------------------------------------
state() {  # prints one line of datapath state for node $1
  local n="$1" rules svc sep ct
  rules=$(node "$n" "iptables-save | grep -c '^-A'"); svc=$(node "$n" "iptables-save -t nat | grep -c KUBE-SVC"); sep=$(node "$n" "iptables-save -t nat | grep -c KUBE-SEP")
  ct=$(node "$n" "cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo -")
  if [ $CILIUM = 1 ]; then
    local cs cl cct; cs=$(cilium_exec "$n" cilium-dbg service list | grep -c LoadBalancer\\\|ClusterIP); cl=$(cilium_exec "$n" cilium-dbg bpf lb list | grep -c ':'); cct=$(cilium_exec "$n" cilium-dbg bpf ct list global | grep -c 'TCP\|UDP')
    printf '  %-14s iptables rules=%-6s KUBE-SVC=%-4s KUBE-SEP=%-4s | cilium services=%-5s bpf lb entries=%-6s bpf ct entries=%-6s nf_conntrack=%s\n' "$n" "$rules" "$svc" "$sep" "$cs" "$cl" "$cct" "$ct"
  else
    local t s pc np
    t=$(kp_metric "$n" 'kubeproxy_sync_proxy_rules_iptables_total{ip_family="IPv4",table="nat"}'); s=$(kp_metric "$n" 'kubeproxy_sync_proxy_rules_duration_seconds_sum'); pc=$(kp_metric "$n" 'kubeproxy_sync_proxy_rules_duration_seconds_count')
    np=$(kp_metric "$n" 'kubeproxy_network_programming_duration_seconds_sum'); npc=$(kp_metric "$n" 'kubeproxy_network_programming_duration_seconds_count')
    printf '  %-14s iptables rules=%-6s KUBE-SVC=%-4s KUBE-SEP=%-4s | kube-proxy nat rules=%-6s sync_duration sum/count=%s/%s  network_programming sum/count=%s/%s  nf_conntrack=%s\n' "$n" "$rules" "$svc" "$sep" "$t" "$s" "$pc" "$np" "$npc" "$ct"
  fi
}

# ---------- 2. programming latency: pre-chosen ClusterIP, poller in the pod starts FIRST ----------
# Prints ms from the Mac issuing `kubectl create` to the pod's first successful HTTP connection,
# skew-corrected. The poller is bash inside the client pod using $EPOCHREALTIME (microseconds).
prog_latency() {  # $1 = index for the ClusterIP and name
  local ip="$SVC_PREFIX.250.$1" name="lat-$1" tmp; tmp=$(mktemp)
  kn exec client -- bash -c "end=\$((SECONDS+60)); while [ \$SECONDS -lt \$end ]; do curl -s -o /dev/null --max-time 0.3 http://$ip/ && { echo \$EPOCHREALTIME; exit 0; }; sleep 0.02; done; echo TIMEOUT" > "$tmp" 2>/dev/null &
  local pid=$!; sleep 1.5      # let kubectl exec establish and the loop start polling
  local t0; t0=$(python3 -c 'import time; print(time.time())')
  printf 'apiVersion: v1\nkind: Service\nmetadata: {name: %s, namespace: %s}\nspec: {clusterIP: %s, selector: {app: web}, ports: [{port: 80, targetPort: 8080}]}\n' "$name" "$NS" "$ip" | kn apply -f - >/dev/null 2>&1
  wait $pid; local t1; t1=$(cat "$tmp"); rm -f "$tmp"
  if [ "$t1" = TIMEOUT ]; then echo "TIMEOUT"; else python3 -c "print(f'{(($t1 - $t0) * 1000) - $SKEW:.0f}')"; fi
}

hdr "1. BASELINE STATE (rig only, no generated services)"
state "$W"; state "$W2"
echo "  services in $NS: $(kn get svc --no-headers | wc -l | tr -d ' ')"

hdr "2. PROGRAMMING LATENCY at scale 0 — ms from 'kubectl create service' to first successful connect (3 samples)"
for i in 1 2 3; do printf '  sample %s: %s ms\n' "$i" "$(prog_latency $i)"; done
kn delete svc lat-1 lat-2 lat-3 >/dev/null 2>&1

hdr "3. RULE COUNT vs SERVICES — generated ClusterIP Services, all selecting the 3 web backends"
prev=0
for N in $SCALES; do
  echo; echo "--- growing to $N services ---"
  python3 - "$N" "$prev" <<'PY' > /tmp/forensic-svcs.yaml
import sys
n, prev = int(sys.argv[1]), int(sys.argv[2])
for i in range(prev + 1, n + 1):
    print(f"---\napiVersion: v1\nkind: Service\nmetadata: {{name: gen-{i:04d}, namespace: forensic, labels: {{gen: 'true'}}}}\nspec:\n  selector: {{app: web}}\n  ports: [{{port: 80, targetPort: 8080}}]")
PY
  t0=$(python3 -c 'import time; print(time.time())')
  kn apply -f /tmp/forensic-svcs.yaml >/dev/null 2>&1
  t1=$(python3 -c 'import time; print(time.time())')
  echo "  apply of $((N-prev)) Services took $(python3 -c "print(f'{$t1-$t0:.1f}')") s (API side)"
  # wait until the datapath has caught up: the LAST generated service answers from the client pod
  last=$(kn get svc "gen-$(printf '%04d' $N)" -o jsonpath='{.spec.clusterIP}')
  for _ in $(seq 1 120); do kn exec client -- curl -s -o /dev/null --max-time 0.5 "http://$last/" 2>/dev/null && break; sleep 0.5; done
  t2=$(python3 -c 'import time; print(time.time())')
  echo "  last service (gen-$(printf '%04d' $N), $last) reachable $(python3 -c "print(f'{$t2-$t0:.1f}')") s after the apply began"
  sleep 3; state "$W"; state "$W2"
  echo "  programming latency at scale $N (3 samples):"; for i in 1 2 3; do printf '    sample %s: %s ms\n' "$i" "$(prog_latency $i)"; done; kn delete svc lat-1 lat-2 lat-3 >/dev/null 2>&1
  prev=$N
done

hdr "4. THROUGHPUT — iperf3 $W2 -> $W, pod IP then via the Service ClusterIP ($RUNS runs each)"
echo "  VM load before: $(loadavg)"
scripts/bench.sh "pod-ip   ($SERVER_IP)" "$CTX" "$NS" client "$SERVER_IP" "$RUNS" | grep -E 'run|median|spread'
scripts/bench.sh "service  (iperf3-server.forensic)" "$CTX" "$NS" client iperf3-server.forensic.svc.cluster.local "$RUNS" | grep -E 'run|median|spread'

hdr "5. CONNECTION CHURN + what the nodes pay — fortio, 64 parallel, Connection: close, 20 s, via the web Service"
echo "  before: $(node "$W" 'cat /proc/sys/net/netfilter/nf_conntrack_count') conntrack entries on $W; VM load $(loadavg)"
kn exec fortio -- fortio load -c 64 -qps 0 -t 20s -H 'Connection: close' -quiet http://web.forensic.svc.cluster.local/ > /tmp/forensic-fortio.txt 2>&1 &
FPID=$!; SECONDS=0
# sample the nodes every ~4 s while the load runs (the docker stats call itself takes ~2 s; the printed t+ is measured, not nominal)
for s in 1 2 3 4; do sleep 4
  ct=$(node "$W" 'cat /proc/sys/net/netfilter/nf_conntrack_count'); cpu=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' "$W" "$W2" | tr '\n' ' ')
  # top -w 200: at the default width top truncates names to "kube-pro+" / "cilium-a+" and nothing matches.
  if [ $CILIUM = 1 ]; then d=$(node "$W" "top -b -n1 -w 200 | awk '/cilium-agent/{s+=\$9} END{print s+0\"%\"}'"); dn=cilium-agent; else d=$(node "$W" "top -b -n1 -w 200 | awk '/kube-proxy/{s+=\$9} END{print s+0\"%\"}'"); dn=kube-proxy; fi
  echo "  t+${SECONDS}s: nf_conntrack($W)=$ct  node CPU: $cpu  $dn on $W: $d"
done
wait $FPID; grep -E 'Code 200|All done|# target 50%|# target 99%|Sockets used' /tmp/forensic-fortio.txt | sed 's/^/  /'
[ $CILIUM = 1 ] && echo "  cilium bpf ct entries on $W after: $(cilium_exec "$W" cilium-dbg bpf ct list global | grep -c 'TCP')"
echo "  after : $(node "$W" 'cat /proc/sys/net/netfilter/nf_conntrack_count') conntrack entries on $W"
echo; echo "  keep-alive comparison (same load, persistent connections, 10 s):"
kn exec fortio -- fortio load -c 64 -qps 0 -t 10s -quiet http://web.forensic.svc.cluster.local/ 2>&1 | grep -E 'All done|# target 50%|# target 99%' | sed 's/^/  /'

hdr "6. CLEANUP — generated services removed, rig kept"
kn delete svc -l gen=true --wait=false >/dev/null 2>&1; sleep 5; echo "  services in $NS now: $(kn get svc --no-headers | wc -l | tr -d ' ')"
