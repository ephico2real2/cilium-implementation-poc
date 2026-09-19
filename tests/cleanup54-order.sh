#!/usr/bin/env bash
# test: demo 54's cleanup.sh waits for the Envoy door Services to be GONE before it
# removes kube-vip-cloud-provider. Those Services are owned by the GatewayClass and
# carry service.kubernetes.io/load-balancer-cleanup; the cloud-provider is what
# clears that finalizer (demo 51 review A1: 66 ms with it running, unbounded with it
# down). Deleting the provider first can leave both Services Terminating for ever
# and the next apply's Gateways never Programmed. PATH-stub: kubectl logs its args.
# usage: bash tests/cleanup54-order.sh [demos/54-eg-poc1-kube-vip/cleanup.sh]   (exit 0 = pass)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CLEANUP=${1:-$R/demos/54-eg-poc1-kube-vip/cleanup.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/54-eg-poc1-kube-vip"
cp "$CLEANUP" "$T/repo/demos/54-eg-poc1-kube-vip/cleanup.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_LOG"\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"
: > "$T/log"
(cd "$T/repo" && STUB_LOG="$T/log" PATH="$T/bin:/usr/bin:/bin" bash demos/54-eg-poc1-kube-vip/cleanup.sh >/dev/null 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { echo "TEST FAIL: cleanup.sh exit $rc under the stub"; cat "$T/log"; exit 1; }

gw_line=$(grep -n -- '-n shop delete gateway' "$T/log" | head -1 | cut -d: -f1)
wait_line=$(grep -nE -- '-n envoy-gateway-system wait svc .*--for=delete' "$T/log" | head -1 | cut -d: -f1)
cp_line=$(grep -n -- 'delete deploy kube-vip-cloud-provider' "$T/log" | head -1 | cut -d: -f1)
[ -n "$gw_line" ] || { echo "TEST FAIL: no gateway delete"; cat "$T/log"; exit 1; }
[ -n "$cp_line" ] || { echo "TEST FAIL: no cloud-provider delete"; cat "$T/log"; exit 1; }
if [ -z "$wait_line" ]; then
  echo "TEST FAIL: cleanup.sh never waits for the Envoy Services (--for=delete) before removing the cloud-provider"
  cat "$T/log"
  exit 1
fi
if ! { [ "$gw_line" -lt "$wait_line" ] && [ "$wait_line" -lt "$cp_line" ]; }; then
  echo "TEST FAIL: order is gateway@$gw_line wait@$wait_line cloud-provider@$cp_line (want gateway < wait < cloud-provider)"
  cat "$T/log"
  exit 1
fi
grep -qE -- 'wait svc .*--timeout=' "$T/log" || { echo "TEST FAIL: the wait has no --timeout"; exit 1; }
echo "TEST PASS: cleanup.sh deletes the Gateways, waits for their Services to be gone, then removes the cloud-provider"
exit 0
