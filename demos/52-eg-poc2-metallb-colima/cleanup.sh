#!/usr/bin/env bash
# cleanup.sh — remove demo 52c's cluster. The fabric and demo 54c's cluster
# are left alone: this demo is the SECOND cluster, and taking the first one
# with it would be a surprise.
#   demos/52-eg-poc2-metallb-colima/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${EG_COLIMA_CLUSTER:=eg-poc2-colima}"
: "${EG_COLIMA_KUBECONFIG:=$HOME/.kube/config-$EG_COLIMA_CLUSTER}"
export EG_COLIMA_CLUSTER EG_COLIMA_KUBECONFIG
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh

if ! fabric_colima_require_ctx; then exit 1; fi
if ! fabric_colima_kind_env; then exit 1; fi

echo "== deleting kind cluster $EG_COLIMA_CLUSTER (the fabric and eg-poc1-colima stay)"
kind delete cluster --name "$EG_COLIMA_CLUSTER" || true
rm -f "$EG_COLIMA_KUBECONFIG"
echo "== left running:"
docker --context "$CTX" ps --format '{{.Names}}' | sort | sed 's/^/   /'
