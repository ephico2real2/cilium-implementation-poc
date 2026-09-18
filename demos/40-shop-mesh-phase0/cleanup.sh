#!/usr/bin/env bash
# cleanup.sh — remove phase 0's doors, leaf, VIP announcer and shared pool. Restores kind-l2-announce
# WITHOUT the shop-vip-gw exclusion (an inline manifest — do not re-apply the pool files, they still
# carry the exclusion on disk). Leaves demo 35's namespaces alone.
#
#   demos/40-shop-mesh-phase0/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

for ctx in kind-poc1 kind-poc2; do
  echo "== $ctx"
  kubectl --context "$ctx" -n shop-edge delete gateway shop-gw shop-vip-gw --ignore-not-found
  kubectl --context "$ctx" -n shop-edge delete certificate shop-tls --ignore-not-found
  # cert-manager here runs WITHOUT --enable-certificate-owner-ref (measured: the Secret has no
  # ownerReferences), so deleting the Certificate leaves its Secret behind. Delete it explicitly.
  kubectl --context "$ctx" -n shop-edge delete secret shop-tls --ignore-not-found
  kubectl --context "$ctx" delete ciliuml2announcementpolicy shop-vip-announce --ignore-not-found
  kubectl --context "$ctx" delete ciliumloadbalancerippool shared-vip-pool --ignore-not-found
done

# Restore the default L2 policy (no serviceSelector) so leftover shop-vip-gw Services — there
# should be none after the Gateway delete — cannot be the only thing a selector change would miss.
# The on-disk pool files keep the exclusion for the next apply.sh.
echo "== restore kind-l2-announce without the shop-vip-gw exclusion"
for ctx in kind-poc1 kind-poc2; do
  kubectl --context "$ctx" apply -f - <<'EOF'
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: kind-l2-announce
spec:
  interfaces:
    - ^eth0$
  externalIPs: false
  loadBalancerIPs: true
EOF
done

echo "phase 0 removed (KEPT: namespace shop-edge on both clusters, and the gateway-access: shop-gw label apply.sh added to it)"
