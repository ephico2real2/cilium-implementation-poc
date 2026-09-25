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

else
  echo "== 2. skipped (--no-cluster): the fabric alone, no node LAN"
fi

echo "== 3. apply — the tables, the events, the screenshots"
"$HERE/apply.sh"

if [ "$want_cluster" -eq 1 ]; then
  # AFTER apply, not before. apply.sh calls fabric-colima-up.sh, which runs
  # `compose up -d --wait` with the BASE file only — and compose reconciles a
  # container to the spec it is given, so an overlay attached beforehand is
  # removed again. Measured: leaf1 came back on link-leaf1-spine and mgmt
  # alone, and servers-join refused because the leaves were not on the node
  # LAN. --no-recreate so the four routers keep the sessions apply just
  # recorded; the change only adds an interface.
  # The overlay first, then `docker network connect` for whatever it did not
  # attach. `--no-recreate` cannot add a network to a RUNNING container —
  # compose would have to recreate it, which is the one thing that flag
  # forbids — so the overlay alone is a no-op on an already-converged fabric.
  # Measured twice here: the leaves came back on link-*-spine and mgmt only.
  # demos/54-eg-poc1-kube-vip-colima/apply.sh has carried this fallback since
  # it met the same wall.
  echo "== 4. attach the leaves to the node LAN"
  fabric_colima_compose_lan up -d --no-recreate --no-build
  leaf_lan_ip() { # container — its address on the node LAN, or empty
    dk inspect -f "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" "$1" 2>/dev/null || true
  }
  for pair in "leaf1 $KIND_EG_COLIMA_LEAF1" "leaf2 $KIND_EG_COLIMA_LEAF2"; do
    leaf=${pair%% *}; want=${pair##* }
    c="${FABRIC_COLIMA_PROJECT}-${leaf}-1"
    got=$(leaf_lan_ip "$c")
    if [ "$got" != "$want" ]; then
      echo "  $leaf not at $want (got ${got:-absent}) — docker network connect"
      dk network connect --ip "$want" "$KIND_EG_COLIMA_NET" "$c" 2>/dev/null || true
      got=$(leaf_lan_ip "$c")
    fi
    echo "  $leaf $KIND_EG_COLIMA_NET=$got"
    [ "$got" = "$want" ] || { echo "demo46-colima-e2e: $leaf is not at $want" >&2; exit 1; }
  done
fi

if [ "$want_cluster" -eq 1 ]; then
  # One implementation, two fabrics: the scripts live in scripts/ and take
  # every difference as a variable. They already DEFAULT to this fabric, so
  # these exports are the ones that differ from a bare run — the cluster, the
  # kubeconfig, the project and the port — plus the kube-vip DaemonSet, which
  # is demo 54c's on this fabric and demo 56's on demo 55's.
  echo "== 5. servers dial in, and a packet crosses to what they announce"
  export CTX_DOCKER="$CTX"
  export FABRIC_DEMO_HERE="$HERE"
  export FABRIC_PROJECT="$FABRIC_COLIMA_PROJECT"
  export FABRIC_DASHBOARD_PORT="$FABRIC_COLIMA_DASHBOARD_PORT"
  export SERVERS_KUBE_CONTEXT="kind-${EG_COLIMA_CLUSTER}"
  export KUBECONFIG="${KUBECONFIG:-$EG_COLIMA_KUBECONFIG}"
  export FABRIC_NODE_LAN="$KIND_EG_COLIMA_NET"
  export FABRIC_LEAF1_LAN="$KIND_EG_COLIMA_LEAF1"
  export FABRIC_LEAF2_LAN="$KIND_EG_COLIMA_LEAF2"
  export FABRIC_KUBEVIP_DS=demos/54-eg-poc1-kube-vip-colima/10b-kube-vip-ds-bgp-active-active.yaml
  export FABRIC_VIP=10.198.0.46
  scripts/fabric-servers-join.sh
  scripts/fabric-traffic.sh
fi

# Through record.sh, into the same transcript apply.sh just appended to. The
# claims gate reads the LAST apply block and wants the check's own footer in
# it ("demo 46-colima check: 0 FAIL") and its seventeen rows; a check that
# only reached the terminal leaves the record saying the run was never judged.
echo "== 6. check"
rc=0
TRANSCRIPT="${FABRIC_TRANSCRIPT:-$HERE/output/transcript.txt}"
scripts/record.sh "$TRANSCRIPT" "$HERE/check.sh" || rc=$?

if [ "$want_gates" -eq 1 ]; then
  echo "== 7. the gates that need no lab"
  bash tests/run-bgp-fabric-gates.sh || rc=$((rc + $?))
  echo "== 8. the gates that need the running fabric"
  FABRIC_DEMO_HERE="$HERE" FABRIC_PROJECT="$FABRIC_COLIMA_PROJECT" CTX_DOCKER="$CTX" \
    bash tests/fabric-agent-mgmt-input.sh || rc=$((rc + $?))
fi

echo
echo "demo46-colima-e2e: dashboard http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/"
echo "demo46-colima-e2e: screenshots $HERE/output/screenshots/"
echo "demo46-colima-e2e: transcript  $HERE/output/transcript.txt"
exit "$rc"
