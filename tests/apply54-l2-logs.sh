#!/usr/bin/env bash
# test: apply.sh's l2_proof reads the WHOLE kube-vip log, not kubectl's 10-line
# default for `logs -l`. The stub kubectl behaves like the real one: with a
# selector and no --tail it prints the last 10 lines per pod; with --tail=-1 it
# prints everything. The line that proves the add — `successful add IP
# address=<ip>` — sits 11th from the end of the worker's log (measured
# 2026-09-19 on kind-eg-poc1), so the default window drops it.
# usage: bash tests/apply54-l2-logs.sh [demos/54-eg-poc1-kube-vip/apply.sh]   (exit 0 = pass)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
APPLY=${1:-$R/demos/54-eg-poc1-kube-vip/apply.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# the worker pod's log as recorded: the add line is 11th from the end
cat > "$T/worker.log" <<'LOG'
2026/09/19 13:14:15 INFO (svcs) adding VIP ip=172.19.255.100 interface=eth0 namespace=envoy-gateway-system name=envoy-shop-http-gw-fccf2727
2026/09/19 13:14:26 INFO successful add IP address=172.19.255.100
2026/09/19 13:14:26 INFO layer 2 broadcaster starting IP=172.19.255.100 device=eth0
2026/09/19 13:14:26 INFO [ARP manager] inserting ARP/NDP instance name=172.19.255.100/32-eth0
I0919 13:14:26.723413 1 leaderelection.go:272] "Successfully acquired lease"
I0919 13:14:26.724375 1 warnings.go:107] "Warning: spec.externalIPs is deprecated"
2026/09/19 13:14:26 INFO [service] service=envoy-shop-http-gw-fccf2727 namespace=envoy-gateway-system
2026/09/19 13:14:26 INFO successful add IP address=172.19.255.101
2026/09/19 13:14:26 INFO layer 2 broadcaster starting IP=172.19.255.101 device=eth0
2026/09/19 13:14:26 INFO [ARP manager] inserting ARP/NDP instance name=172.19.255.101/32-eth0
I0919 13:14:26.730016 1 warnings.go:107] "Warning: spec.externalIPs is deprecated"
2026/09/19 13:14:26 INFO [service] service=envoy-shop-grpc-gw-8c4f0319 namespace=envoy-gateway-system
LOG
cat > "$T/bin/kubectl" <<STUB
#!/usr/bin/env bash
# real kubectl: "--tail=-1 ... showing all log lines otherwise 10, if a selector is provided"
if [[ " \$* " == *" logs "* ]]; then
  if [[ " \$* " == *"--tail=-1"* ]]; then cat "$T/worker.log"; else tail -10 "$T/worker.log"; fi
else
  echo ok
fi
STUB
# docker/kind: enough for l2_proof to reach the log step
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *arping*) for i in 1 2 3; do echo "Unicast reply from ${@: -1} [fa:1f:d6:0f:1e:ae] 0.01ms"; done ;;
  inspect*) echo "fa:1f:d6:0f:1e:ae" ;;
  exec*) echo "    inet 172.19.255.100/32 scope global deprecated eth0" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho eg-poc1-worker\n' > "$T/bin/kind"
chmod +x "$T/bin/"*

# lift l2_proof out of apply.sh and run it alone
sed -n '/^l2_proof() {/,/^}/p' "$APPLY" > "$T/l2_proof.sh"
grep -q 'l2_proof()' "$T/l2_proof.sh" || { echo "TEST FAIL: l2_proof() not found in $APPLY"; exit 1; }
out=$(cd "$T" && CTX=kind-eg-poc1 CLUSTER=eg-poc1 PATH="$T/bin:/usr/bin:/bin" \
  bash -c 'source ./l2_proof.sh; l2_proof 172.19.255.100' 2>&1)

if ! printf '%s\n' "$out" | grep -q 'successful add IP address=172.19.255.100'; then
  echo "TEST FAIL: l2_proof lost 'successful add IP address=172.19.255.100' (kubectl logs -l default tail=10)"
  printf '%s\n' "$out" | sed -n '/kube-vip DS logs/,$p'
  exit 1
fi
echo "TEST PASS: l2_proof reads the whole kube-vip log; 'successful add IP' for .100 is in the record"
exit 0
