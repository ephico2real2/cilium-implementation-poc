#!/usr/bin/env bash
# test: eg-vip-move.sh must wait for the OTHER cluster's Envoy Service (the actual
# announcement) to be gone after deleting its Gateway and BEFORE applying to the target.
# usage: bash tests/eg-vip-move-waits-for-service.sh scripts/eg-vip-move.sh   (exit 0 = test passes)
set -uo pipefail
MOVE=${1:?eg-vip-move.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/scripts" "$T/repo/demos/51-eg-kube-vip"
cp "$MOVE" "$T/repo/scripts/eg-vip-move.sh"
ROOT=$(cd "$(dirname "$MOVE")/.." && pwd)
cp "$ROOT"/demos/51-eg-kube-vip/30-gateways-eg?.yaml "$ROOT"/demos/51-eg-kube-vip/50-routes-eg?.yaml "$T/repo/demos/51-eg-kube-vip/"
cat > "$T/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >> "$T/calls.log"
case "\$*" in
  *"get deploy"*"-o name"*) echo deployment.apps/envoy-shop-eg-vip-gw-135d4d6a ;;
  *"apply -f -"*) cat >/dev/null; echo applied ;;
esac
exit 0
STUB
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in *arping*) echo "Unicast reply from 172.19.255.16 [aa:bb:cc:dd:ee:ff] 0.1ms";; *"network inspect"*) echo '[{"Containers":{}}]';; esac
exit 0
STUB
chmod +x "$T/bin/"*
(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash scripts/eg-vip-move.sh kube-vip eg2 >/dev/null 2>&1) || { echo "TEST FAIL: script exited non-zero"; exit 1; }
del=$(grep -n 'kind-eg1 -n shop delete gateway eg-vip-gw' "$T/calls.log" | head -1 | cut -d: -f1)
wt=$(grep -n 'kind-eg1 -n envoy-gateway-system wait svc -l gateway.envoyproxy.io/owning-gateway-name=eg-vip-gw --for=delete' "$T/calls.log" | head -1 | cut -d: -f1)
ap=$(grep -n 'kind-eg2 apply -f -' "$T/calls.log" | head -1 | cut -d: -f1)
[ -n "$del" ] && [ -n "$ap" ] || { echo "TEST FAIL: delete/apply calls missing"; exit 1; }
[ -n "$wt" ] || { echo "TEST FAIL: no wait --for=delete on eg1's Envoy Service before applying to eg2"; exit 1; }
[ "$del" -lt "$wt" ] && [ "$wt" -lt "$ap" ] || { echo "TEST FAIL: order wrong (delete=$del wait=$wt apply=$ap)"; exit 1; }
echo "TEST PASS: delete gateway ($del) -> wait Service gone ($wt) -> apply target ($ap)"
