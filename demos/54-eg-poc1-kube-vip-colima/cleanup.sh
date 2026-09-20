#!/usr/bin/env bash
# cleanup.sh — remove demo 54c's door and kube-vip. Leaves the cluster,
# the registry, the kind-eg-colima LAN, the fabric, and the Colima VM.
# Does not touch Desktop's bgp-fabric, eg-poc1, eg-poc2, md5lab or CRC.
#   demos/54-eg-poc1-kube-vip-colima/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
if ! fabric_colima_require_ctx; then
  exit 1
fi

fabric_colima_save_ctx
trap fabric_colima_restore_ctx EXIT

if ! fabric_colima_kind_env; then
  exit 1
fi

KCTX="kind-$EG_COLIMA_CLUSTER"
echo "== $KCTX — demo 54c cleanup (fabric and cluster stay)"
if kubectl --context "$KCTX" get --raw /readyz >/dev/null 2>&1; then
  kubectl --context "$KCTX" delete ns door --ignore-not-found --wait=false
  kubectl --context "$KCTX" -n kube-system delete deploy kube-vip-cloud-provider --ignore-not-found
  kubectl --context "$KCTX" -n kube-system delete ds kube-vip-ds --ignore-not-found
  kubectl --context "$KCTX" -n kube-system delete cm kubevip --ignore-not-found
  kubectl --context "$KCTX" delete clusterrolebinding system:kube-vip-binding system:kube-vip-cloud-controller-binding --ignore-not-found
  kubectl --context "$KCTX" delete clusterrole system:kube-vip-role system:kube-vip-cloud-controller-role --ignore-not-found
  kubectl --context "$KCTX" -n kube-system delete sa kube-vip kube-vip-cloud-controller --ignore-not-found
else
  echo "cluster $KCTX not reachable — objects already gone or kubeconfig missing"
fi
echo "demo 54c removed (KEPT: cluster $EG_COLIMA_CLUSTER, registry $KIND_REGISTRY_NAME, fabric $FABRIC_COLIMA_PROJECT, Colima profile $FABRIC_COLIMA_PROFILE; Desktop untouched)"
echo "to delete the cluster: KIND_EXPERIMENTAL_DOCKER_NETWORK=$KIND_EG_COLIMA_NET kind delete cluster --name $EG_COLIMA_CLUSTER --kubeconfig $EG_COLIMA_KUBECONFIG"
