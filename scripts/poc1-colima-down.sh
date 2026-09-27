#!/usr/bin/env bash
# poc1-colima-down.sh — delete poc1 from the Colima profile cilium-poc1 (issue #86) and the DOCKER-USER accept that
# poc1-colima-up.sh added in the VM. The VM, the `kind` docker network and the pulled images stay, so the next up
# is a cluster create, not a VM build. Same gate as the up: colima-cilium-poc1 only, never desktop-linux.
#
#   scripts/poc1-colima-down.sh
#   colima stop --profile cilium-poc1        # the VM too, when the lab is done for the day (start: colima start --profile cilium-poc1)
set -euo pipefail
cd "$(dirname "$0")/.."
CTX="${CTX:-colima-cilium-poc1}"
FABRIC_COLIMA_PROFILE="${FABRIC_COLIMA_PROFILE:-cilium-poc1}"
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
FABRIC_COLIMA_EXPECT_CTX=colima-cilium-poc1   # after the source: the gate accepts this lab's VM and nothing else

POC1_COLIMA_KUBECONFIG="${POC1_COLIMA_KUBECONFIG:-$HOME/.kube/poc1-colima.config}"
POOLS=172.18.255.0/24

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
if ! fabric_colima_require_ctx; then
  exit 1
fi
if ! fabric_colima_kind_env; then
  exit 1
fi
unset KIND_EXPERIMENTAL_DOCKER_NETWORK
export KUBECONFIG="$POC1_COLIMA_KUBECONFIG"

# lab-down.sh with the name: without one it deletes every cluster the engine has
scripts/lab-down.sh poc1
if br=$(KIND_EG_COLIMA_NET=kind fabric_colima_kind_bridge); then
  colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sudo sh -c \
    "while iptables -D DOCKER-USER -d $POOLS -o $br -j ACCEPT 2>/dev/null; do :; done; iptables -S DOCKER-USER"
fi
echo "poc1-colima-down: poc1 deleted from $CTX; the VM, the kind network and the images stay."
echo "  the Mac's route, if the operator added it: sudo route -n delete -net $POOLS"
echo "  the VM: colima stop --profile $FABRIC_COLIMA_PROFILE"
