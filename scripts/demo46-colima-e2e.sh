#!/usr/bin/env bash
# demo46-colima-e2e.sh — demo 46 end to end on this machine, the way CI runs
# it: the Colima VM, the four-router fabric, the node LAN, a kind cluster on
# that LAN, the leaves attached to it, the recorded apply with its
# screenshots, check.sh, and the gates.
#
#   scripts/demo46-colima-e2e.sh              # everything
#   scripts/demo46-colima-e2e.sh --no-cluster # the fabric alone, no kind
#   scripts/demo46-colima-e2e.sh --no-gates   # skip the gate sweep at the end
#
# It only ever brings things UP. Nothing here removes a container, a cluster or
# a VM — `demos/46-bgp-fabric-colima/cleanup.sh` and `scripts/eg-down.sh` do
# that, on purpose and separately, because this machine runs several labs on
# several Docker contexts and a teardown in the wrong one is not recoverable
# by re-running anything.
#
# Every docker call goes through the fabric-colima-lib.sh context gate, so a
# wrong CTX is refused before the first daemon call rather than after it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh

want_cluster=1
want_gates=1
for arg in "$@"; do
  case "$arg" in
    --no-cluster) want_cluster=0 ;;
    --no-gates)   want_gates=0 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--no-cluster] [--no-gates]" >&2; exit 2 ;;
  esac
done

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi

HERE=demos/46-bgp-fabric-colima

echo "== 1. the VM, the images and the four routers"
scripts/fabric-colima-up.sh

if [ "$want_cluster" -eq 1 ]; then
  echo "== 2. the node LAN and a kind cluster on it"
  scripts/eg-colima-up.sh

  echo "== 3. attach the leaves to the node LAN"
  # --no-recreate: the four routers are already up and converged from step 1;
  # recreating them would restart BGP for a change that only adds an interface.
  fabric_colima_compose_lan up -d --no-recreate --wait
  fabric_colima_compose_lan exec -T leaf1 ip -brief addr show
  fabric_colima_compose_lan exec -T leaf2 ip -brief addr show
else
  echo "== 2-3. skipped (--no-cluster): the fabric alone, no node LAN"
fi

echo "== 4. apply — the tables, the events, the screenshots"
"$HERE/apply.sh"

if [ "$want_cluster" -eq 1 ]; then
  # One implementation, two fabrics: the scripts live in demos/46-bgp-fabric
  # and take every difference as a variable. The Colima values below are this
  # fabric's own — its node LAN, its leaf addresses on it, its cluster, its
  # port, and a VIP from ITS prefix-list block (10.198.0.0/26, not 10.98's).
  echo "== 4b. servers dial in, and a packet crosses to what they announce"
  export DEMO46_HERE="$HERE"
  export CTX_DOCKER="$CTX"
  export FABRIC_PROJECT="$FABRIC_COLIMA_PROJECT"
  export FABRIC_DASHBOARD_PORT="$FABRIC_COLIMA_DASHBOARD_PORT"
  export SERVERS_KUBE_CONTEXT="kind-${EG_COLIMA_CLUSTER}"
  export KUBECONFIG="${KUBECONFIG:-$EG_COLIMA_KUBECONFIG}"
  export DEMO46_NODE_LAN="$KIND_EG_COLIMA_NET"
  export DEMO46_LEAF1_LAN="$KIND_EG_COLIMA_LEAF1"
  export DEMO46_LEAF2_LAN="$KIND_EG_COLIMA_LEAF2"
  export DEMO46_KUBEVIP_DS=demos/54-eg-poc1-kube-vip-colima/10b-kube-vip-ds-bgp-active-active.yaml
  export DEMO46_VIP=10.198.0.46
  export DEMO46_PROBE_MANIFEST=demos/46-bgp-fabric/probe/10-probe.yaml
  demos/46-bgp-fabric/servers-join.sh
  demos/46-bgp-fabric/traffic.sh
fi

echo "== 5. check"
rc=0
"$HERE/check.sh" || rc=$?

if [ "$want_gates" -eq 1 ]; then
  echo "== 6. the gates that need no lab"
  bash tests/run-demo46-gates.sh || rc=$((rc + $?))
  echo "== 7. the gates that need the running fabric"
  bash tests/fabric-agent-mgmt-input.sh || rc=$((rc + $?))
fi

echo
echo "demo46-colima-e2e: dashboard http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/"
echo "demo46-colima-e2e: screenshots $HERE/output/screenshots/"
echo "demo46-colima-e2e: transcript  $HERE/output/transcript.txt"
exit "$rc"
