#!/usr/bin/env bash
# noisy-neighbour.sh — phase 3.1 of enhancement 005, the controlled experiment: does a team's own Gateway isolate it from
# load on the platform's? Every run records what the review named as confounders — the L2 lease holder of each VIP (two
# Gateways may be announced by two nodes, i.e. two Envoy processes), pod placement, cilium-envoy CPU per node, and the
# HOST's state (macOS compressor and swap: CRC beside the Docker VM is part of the measurement, not a footnote) — and
# reads every probe as the change from the idle baseline taken in the same invocation.
#   demos/37-two-gateways/noisy-neighbour.sh [load_qps] [duration] [runs]        # defaults 0 (= max rate) 30s 3; CONNS=64
# Output: one JSON line per probe under output/perf/<timestamp>/, and a table on stdout. Exits 0; the numbers are the finding.
set -uo pipefail; cd "$(dirname "$0")/../.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; k() { kubectl --context "$CTX" "$@"; }
QPS="${1:-0}"; T="${2:-30s}"; RUNS="${3:-3}"; PROBE_QPS=20; CONNS="${CONNS:-64}"   # qps 0 = fortio's maximum rate: saturate the listener, not the app
OUT="demos/37-two-gateways/output/perf/$(date -u +%Y%m%dT%H%MZ)"; mkdir -p "$OUT"
RGW=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}'); TGW=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.addresses[0].value}')
CA=/ca/ca.crt
# a fortio run from a pod: -resolve pins the hostname to a door's VIP, so SNI and Host are the real name; JSON to stdout
fortio() { # <pod> <qps> <conns> <url> <resolve-ip|->  → p50 p99 actual_qps errors
  local pod=$1 qps=$2 c=$3 url=$4 ip=$5 res
  res=$(k -n loadtest exec "$pod" -- fortio load -quiet -json - -qps "$qps" -c "$c" -t "$T" -nocatchup -uniform ${ip:+-resolve $ip} -cacert $CA "$url" 2>/dev/null)
  printf '%s' "$res" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("nan nan nan nan"); sys.exit()
h=d["DurationHistogram"]; p={x["Percentile"]:x["Value"]*1000 for x in h.get("Percentiles",[])}
codes=d.get("RetCodes",{}); ok=codes.get("200",0); tot=sum(codes.values()) or 1
nan=float("nan"); p50=p.get(50,nan); p99=p.get(99,nan); qps=d.get("ActualQPS",0)
print("%.2f %.2f %.0f %d" % (p50, p99, qps, tot-ok))'
}
envoy_cpu() { # cores per node, 2 m window (the hub scrapes every 30 s), from the hub Prometheus (cadvisor); call it MID-load
  k get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("sum by (node) (rate(container_cpu_usage_seconds_total{container=\"cilium-envoy\"}[2m]))"))')" 2>/dev/null \
    | python3 -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]
print(" ".join("%s=%.2f" % (x["metric"].get("node","?"), float(x["value"][1])) for x in r) or "n/a")' 2>/dev/null
}
context() {
  echo "  leases: $(k -n kube-system get leases -o json | jq -r '.items[] | select(.metadata.name|test("l2announce-(routes|team-b)")) | "\(.metadata.name|sub("cilium-l2announce-";"")) → \(.spec.holderIdentity)"' | tr '\n' ';')"
  echo "  pods: $(k get pods -A -o json | jq -r '.items[] | select(.metadata.namespace|test("^team|loadtest")) | "\(.metadata.namespace)/\(.metadata.labels.app // .metadata.name)@\(.spec.nodeName|sub("poc1-";""))"' | sort | tr '\n' ' ')"
  echo "  host: $(top -l 1 -n 0 | awk '/PhysMem/ {print $2" used, "$(NF-1)" unused"}' 2>/dev/null), compressor $(top -l 1 -n 0 | grep -oE '[0-9]+[MG] compressor'), swap $(sysctl -n vm.swapusage | awk '{print $6}'); CRC: $(crc status 2>/dev/null | awk -F': +' '/^CRC VM/ {print $2; exit}' || echo n/a)"
  echo "  cilium-envoy CPU (cores): $(envoy_cpu)"
}
loadrun() { # <resolve-ip|""> <url> [pod]: the load from the `load` pod (or another); its own numbers are a record too; Envoy CPU sampled mid-way
  local ip=$1 url=$2 pod=${3:-load} r mid
  [ "${NO_SAMPLER:-0}" = 1 ] || ( sleep $(( ${T%s} / 2 + 3 )); echo "  envoy CPU mid-load: $(envoy_cpu)" ) &
  # the load outlives the probes by 6 s (they start 3 s after it), so every probe sample is taken under load
  r=$(T="$(( ${T%s} + 6 ))s" fortio "$pod" "$QPS" "$CONNS" "$url" "$ip"); set -- $r
  printf '  %-34s p50 %7s ms  p99 %7s ms  qps %5s  errors %s   ← the load itself (%s)\n' "load $url" "$1" "$2" "$3" "$4" "$pod"
  printf '{"phase":"%s","label":"load %s","p50_ms":%s,"p99_ms":%s,"qps":%s,"errors":%s,"pod":"%s"}\n' "$PHASE" "$url" "$1" "$2" "$3" "$4" "$pod" >> "$OUT/probes.jsonl"
}
# probes run CONCURRENTLY, all inside the load window (the first version ran them one after another, 30 s each, against a
# 30 s load: the second probe measured the quiet after the load — retracted in the README). Each `probe` starts a fortio in
# the background and writes its line to a temp file; `probes_done` prints them in order and appends the records.
PROBE_FILES=()
probe() { # <label> <url> <ip>
  local label=$1 url=$2 ip=$3 f; f=$(mktemp); PROBE_FILES+=("$f")
  ( r=$(fortio probe $PROBE_QPS 4 "$url" "$ip"); printf '%s\t%s\n' "$label" "$r" > "$f" ) &
}
probes_done() {
  wait; local f label r leases; leases=$(k -n kube-system get leases -o json | jq -r '[.items[] | select(.metadata.name|test("l2announce-(routes|team-b)")) | .spec.holderIdentity] | join("/")')
  for f in "${PROBE_FILES[@]}"; do
    IFS=$'\t' read -r label r < "$f"; set -- $r
    printf '  %-34s p50 %7s ms  p99 %7s ms  qps %4s  errors %s\n' "$label" "$1" "$2" "$3" "$4"
    printf '{"phase":"%s","label":"%s","p50_ms":%s,"p99_ms":%s,"qps":%s,"errors":%s,"leases":"%s"}\n' "$PHASE" "$label" "$1" "$2" "$3" "$4" "$leases" >> "$OUT/probes.jsonl"
    rm -f "$f"
  done; PROBE_FILES=()
}
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }

say "the rig: load and probe pods both on the worker (one Envoy), the four upstreams on the control plane; routes-gw $RGW, team-b-gw $TGW; load $QPS qps × $CONNS conns × $T, probes $PROBE_QPS qps, $RUNS runs"
context
# warm-up, excluded from every number: connections, TLS sessions and Envoy's clusters warmed on both doors first, so no
# probe below is anyone's first request
say "warm-up (not recorded)"; for u in "https://shop-a.poc.local/ $RGW" "https://probe.team-b.poc.local/ $TGW"; do set -- $u; k -n loadtest exec probe -- fortio load -quiet -qps 50 -c 4 -t 10s -resolve "$2" -cacert $CA "$1" >/dev/null 2>&1; done
for run in $(seq 1 "$RUNS"); do
  say "run $run/$RUNS — 0. idle baseline"; PHASE=baseline
  probe "shop-a via routes-gw (.240)"        https://shop-a.poc.local/        "$RGW"
  probe "probe-a via routes-gw (.240)"       https://probe-a.poc.local/       "$RGW"
  probe "probe-b via team-b-gw (.243)"       https://probe.team-b.poc.local/  "$TGW"
  probe "shop-a direct (Service, no Envoy)"  http://shop.team-a.svc:8080/     ""
  probes_done

  say "run $run/$RUNS — 1. load on shop-a via routes-gw; probe the same door and the team door"; PHASE=load-shared
  loadrun "$RGW" https://shop-a.poc.local/ & LP=$!; sleep 3
  probe "probe-a via routes-gw (.240)  ← same door"  https://probe-a.poc.local/      "$RGW"
  probe "probe-b via team-b-gw (.243) ← other door"  https://probe.team-b.poc.local/ "$TGW"
  probe "shop-a direct (Service, no Envoy)"          http://shop.team-a.svc:8080/    ""
  probes_done

  say "run $run/$RUNS — 2. load on shop-b via team-b-gw; probe the platform door and the team door"; PHASE=load-team
  loadrun "$TGW" https://shop.team-b.poc.local/ & LP=$!; sleep 3
  probe "probe-a via routes-gw (.240)  ← other door"  https://probe-a.poc.local/      "$RGW"
  probe "probe-b via team-b-gw (.243) ← same door"    https://probe.team-b.poc.local/ "$TGW"
  probes_done

  say "run $run/$RUNS — 3. BOTH doors loaded at once: team-a's load on routes-gw, team-b's on team-b-gw; probe both"; PHASE=load-both
  loadrun "$RGW" https://shop-a.poc.local/ load & LP=$!
  NO_SAMPLER=1 loadrun "$TGW" https://shop.team-b.poc.local/ load-b & sleep 3
  probe "probe-a via routes-gw (.240)  ← loaded door"  https://probe-a.poc.local/      "$RGW"
  probe "probe-b via team-b-gw (.243) ← loaded door"   https://probe.team-b.poc.local/ "$TGW"
  probes_done

  say "run $run/$RUNS — 4. team-a's traffic THROUGH team-b's door (shop-a.team-b.poc.local, the ReferenceGrant route) beside team-b's own load, same door"; PHASE=load-same-door
  loadrun "$TGW" https://shop.team-b.poc.local/ load & LP=$!
  NO_SAMPLER=1 loadrun "$TGW" https://shop-a.team-b.poc.local/ load-b & sleep 3
  probe "probe-a via routes-gw (.240)  ← other door"  https://probe-a.poc.local/      "$RGW"
  probe "probe-b via team-b-gw (.243) ← the loaded door" https://probe.team-b.poc.local/ "$TGW"
  probes_done

  say "run $run/$RUNS — 5. control: load direct to the Service (no Envoy in the loaded path)"; PHASE=load-direct
  loadrun "" http://shop.team-a.svc:8080/ & LP=$!; sleep 3
  probe "probe-a via routes-gw (.240)"       https://probe-a.poc.local/       "$RGW"
  probe "probe-b via team-b-gw (.243)"       https://probe.team-b.poc.local/  "$TGW"
  probes_done
done
say "context after"; context
echo; echo "records: $OUT/probes.jsonl ($(wc -l < "$OUT/probes.jsonl") probes)"
