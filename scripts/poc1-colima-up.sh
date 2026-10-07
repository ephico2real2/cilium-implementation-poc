#!/usr/bin/env bash
# poc1-colima-up.sh — the Cilium lab's poc1, ALONE, on the Colima profile cilium-poc1 (issue #86): no poc2, no
# ClusterMesh, no BGP fabric. The Cilium install is not forked: this wrapper points the unchanged scripts/lab-up.sh at
# the VM's engine and runs `lab-up.sh poc1` on the laptop's full-size clusters/poc1.yaml (3 control planes + 2 workers).
#
# Modelled on eg-colima-up.sh (enhancement 008, demo 54c):
#   - CTX and FABRIC_COLIMA_PROFILE name one lab and pass the fabric-colima-lib.sh gate, which here accepts only
#     colima-cilium-poc1 — never desktop-linux, never the fabric's bgp-fabric VM;
#   - this script's own docker calls carry --context "$CTX"; lab-up.sh's and kind's go through DOCKER_HOST (the
#     context's socket — kind has no --context flag), so the active context is never switched;
#   - KUBECONFIG is a dedicated file under $HOME, set here and not inherited, so neither ~/.kube/config nor CRC's
#     contexts are ever written.
# What lab-up.sh assumes about Docker Desktop, walked against this VM on 2026-09-26:
#   - the preflight's two Desktop rows (the app and its settings; the route via Desktop's eth1) describe a VM the lab
#     is not on — LAB_COLIMA_PROFILE switches those rows to the Colima VM (scripts/lab-preflight.sh);
#   - the kind network, kind create, Cilium, Hubble, cert-manager, trust-manager, Tetragon: docker, kind, helm,
#     kubectl and cilium through DOCKER_HOST and KUBECONFIG — unchanged;
#   - the Mac's route to the pools (lab-route.sh: Desktop's eth1): step 3 below instead — a DOCKER-USER accept in the
#     VM and a route to its --network-address; the Mac's route stays the operator's sudo, printed, never run.
#
#   scripts/poc1-colima-up.sh      # idempotent: an existing cluster is kept, every release upgraded with the same values
#   scripts/poc1-colima-down.sh    # deletes the cluster; the VM stays
set -euo pipefail
cd "$(dirname "$0")/.."
CTX="${CTX:-colima-cilium-poc1}"
FABRIC_COLIMA_PROFILE="${FABRIC_COLIMA_PROFILE:-cilium-poc1}"
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
FABRIC_COLIMA_EXPECT_CTX=colima-cilium-poc1   # after the source: the gate accepts this lab's VM and nothing else

POC1_COLIMA_KUBECONFIG="${POC1_COLIMA_KUBECONFIG:-$HOME/.kube/poc1-colima.config}"
TRANSCRIPT="${POC1_COLIMA_TRANSCRIPT:-output/poc1-colima/transcript.txt}"
# every cluster's /26 of the reserved range (cilium/lb-ippool-*.yaml): the prefix of the VM rule and the Mac route
POOLS=172.18.255.0/24
export RECORD_STRICT=1

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
# lab-up.sh's network is `kind` (172.18.0.0/16, the subnet the pools are pinned to), not the eg family's
# kind-eg-colima that fabric_colima_kind_env defaults to
unset KIND_EXPERIMENTAL_DOCKER_NETWORK
export KUBECONFIG="$POC1_COLIMA_KUBECONFIG" LAB_COLIMA_PROFILE="$FABRIC_COLIMA_PROFILE" LAB_CLUSTERS_DIR=clusters
mkdir -p "$(dirname "$TRANSCRIPT")" "$(dirname "$KUBECONFIG")"

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
say() { printf '\n== %s  (%s)\n' "$1" "$(date -u +%H:%M:%SZ)"; }
die() { echo "poc1-colima-up: $1" >&2; exit 1; }

started=$(date +%s)
{
  echo
  echo "=== poc1-colima-up.sh start $(date -u +%Y-%m-%dT%H:%M:%SZ) cluster=poc1 ctx=$CTX profile=$FABRIC_COLIMA_PROFILE ==="
  echo "=== Cilium, no kube-proxy, no poc2, no mesh, no BGP; clusters/poc1.yaml (3 control planes + 2 workers) ==="
  echo "=== DOCKER_HOST=$DOCKER_HOST kubeconfig=$KUBECONFIG ==="
} | tee -a "$TRANSCRIPT"

# ---------------------------------------------------------------- (0) inotify
# Ubuntu ships fs.inotify.max_user_instances=128. eg-colima-up.sh measured a second kind cluster dying on it
# ("inotify_init: too many open files", 2026-09-21). poc1 alone already needs more than 128: with the lab up (five
# nodes, Cilium, Hubble, cert-manager, Tetragon) the VM held 219 inotify instances, measured 2026-09-26 with
# `find /proc/*/fd -lname anon_inode:inotify | wc -l`. 512 is kind's known-issues value.
say "0. inotify limits in the VM"
want_instances=512
have=$(colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
if [ "${have:-0}" -lt "$want_instances" ]; then
  rec colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sudo sh -c "printf 'fs.inotify.max_user_instances = %s\nfs.inotify.max_user_watches = 1048576\n' $want_instances > /etc/sysctl.d/99-kind-inotify.conf && sysctl -q -p /etc/sysctl.d/99-kind-inotify.conf"
else
  rec echo "fs.inotify.max_user_instances=$have already >= $want_instances"
fi

# ---------------------------------------------------------------- (1) the lab, unchanged
say "1. scripts/lab-up.sh poc1 against $CTX (LAB_CLUSTERS_DIR=clusters)"
rec scripts/lab-up.sh poc1

# ---------------------------------------------------------------- (2) what the lab promises, read back
say "2. poc1 on $CTX: the nodes, Cilium, kube-proxy, Hubble, an address"
rec kubectl config get-contexts
rec docker --context "$CTX" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
rec kubectl --context kind-poc1 get nodes -o wide
rec cilium status --context kind-poc1 --wait --wait-duration 5m --interactive=false
rec kubectl --context kind-poc1 -n kube-system get ds
if kubectl --context kind-poc1 -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  die "a kube-proxy DaemonSet exists on poc1"
fi
echo "kube-proxy: no DaemonSet in kube-system" | tee -a "$TRANSCRIPT"
rec kubectl --context kind-poc1 -n kube-system rollout status deploy/hubble-relay --timeout=2m
rec kubectl --context kind-poc1 -n kube-system get svc hubble-ui hubble-relay
lb=$(kubectl --context kind-poc1 -n kube-system get svc hubble-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -n "$lb" ] || die "hubble-ui has no LoadBalancer address"

# ---------------------------------------------------------------- (3) the Mac's path to the pools
# Two pieces, as demo 54c measured them (enhancement 008 D5): Docker 29's FORWARD policy is DROP and DOCKER-FORWARD
# accepts only what enters from a docker bridge, so a packet the Mac routes to the VM's col0 is dropped before the
# `kind` bridge — the DOCKER-USER accept lets the pools through (the VM's own passwordless sudo, not the Mac's). The
# pool addresses are on-link on that bridge, answered by Cilium's L2 announcement, so the VM needs no route of its
# own. The Mac's route to the VM's --network-address is the operator's sudo: printed here, never run.
say "3. the Mac's path to $POOLS: a DOCKER-USER accept in the VM, the Mac's route (the operator's sudo)"
br=$(KIND_EG_COLIMA_NET=kind fabric_colima_kind_bridge) || die "cannot read the bridge of the kind network"
rec colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sudo sh -c \
  "iptables -C DOCKER-USER -d $POOLS -o $br -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -d $POOLS -o $br -j ACCEPT; iptables -S DOCKER-USER"
addr=$(fabric_colima_vm_address)
if [ -z "$addr" ]; then
  echo "Mac: profile $FABRIC_COLIMA_PROFILE has no --network-address; no Mac route can reach it:" | tee -a "$TRANSCRIPT"
  echo "  colima stop --profile $FABRIC_COLIMA_PROFILE && colima start --profile $FABRIC_COLIMA_PROFILE --network-address --activate=false" | tee -a "$TRANSCRIPT"
else
  gw=$(route -n get "$lb" 2>/dev/null | awk '$1 == "gateway:" {print $2; exit}' || true)
  if [ "$gw" = "$addr" ]; then
    echo "Mac route: $POOLS via $addr (present)" | tee -a "$TRANSCRIPT"
    rec curl -s -o /dev/null -w "hubble-ui http://$lb/ → %{http_code}\n" --connect-timeout 5 --max-time 10 "http://$lb/"
  else
    {
      echo "Mac route absent (the kernel would use ${gw:-no gateway} for $lb). The operator runs, once per VM start:"
      echo "  sudo route -n add -net $POOLS $addr"
    } | tee -a "$TRANSCRIPT"
  fi
  # the names, from live state (hosts-entries.sh never edits /etc/hosts)
  block=$(CTX=kind-poc1 scripts/hosts-entries.sh 2>/dev/null)
  missing=$(printf '%s\n' "$block" | grep -v '^#' | while read -r ip names; do
    for n in $names; do
      awk -v ip="$ip" -v n="$n" '$1 == ip { for (i = 2; i <= NF; i++) if ($i == n) f = 1 } END { exit !f }' /etc/hosts || echo "$n"
    done
  done)
  if [ -z "$missing" ]; then
    echo "/etc/hosts: every name poc1 serves is already there, at its live address" | tee -a "$TRANSCRIPT"
  else
    {
      echo "/etc/hosts lacks: $(echo "$missing" | tr '\n' ' '). The operator runs:"
      echo "  KUBECONFIG=$KUBECONFIG scripts/hosts-entries.sh | sudo tee -a /etc/hosts"
    } | tee -a "$TRANSCRIPT"
  fi
fi

echo "poc1-colima-up: done in $(( $(date +%s) - started )) s. poc1 on $CTX; kubeconfig $KUBECONFIG; hubble-ui $lb" | tee -a "$TRANSCRIPT"
