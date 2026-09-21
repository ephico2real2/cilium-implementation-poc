#!/usr/bin/env bash
# fabric-colima-lib.sh — shared context gate for the Colima fabric (demo 46).
# Source from the repo root after `cd` there. Never rely on the active Docker
# context: every daemon call is `docker --context "$CTX"`.
#
# The Desktop fabric (project bgp-fabric, port 8088), colima-md5lab, kind
# clusters and CRC are off-limits. A stray `docker context use` orphans the
# other lab — measured 2026-09-20 — so callers that might switch (colima start
# --activate) restore the previous context in an EXIT trap.
#
#   CTX                         docker context (must be colima-bgp-fabric)
#   FABRIC_COLIMA_PROFILE       Colima profile (bgp-fabric)
#   FABRIC_COLIMA_PROJECT       compose project (bgp-fabric-colima)
#   FABRIC_COLIMA_DASHBOARD_PORT  published on 127.0.0.1 (default 8098)
set -uo pipefail

CTX="${CTX:-colima-bgp-fabric}"
FABRIC_COLIMA_PROFILE="${FABRIC_COLIMA_PROFILE:-bgp-fabric}"
FABRIC_COLIMA_PROJECT="${FABRIC_COLIMA_PROJECT:-bgp-fabric-colima}"
FABRIC_COLIMA_DASHBOARD_PORT="${FABRIC_COLIMA_DASHBOARD_PORT:-8098}"
FABRIC_COLIMA_HERE="${FABRIC_COLIMA_HERE:-demos/46-bgp-fabric-colima}"
FABRIC_COLIMA_FABRIC="${FABRIC_COLIMA_FABRIC:-$FABRIC_COLIMA_HERE/fabric}"
FABRIC_COLIMA_ROUTER_IMAGE="${FABRIC_ROUTER_IMAGE:-frr-agent:colima}"
FABRIC_COLIMA_DASHBOARD_IMAGE="${FABRIC_DASHBOARD_IMAGE:-bgp-dashboard:colima}"
export FABRIC_COLIMA_ROUTER_IMAGE FABRIC_COLIMA_DASHBOARD_IMAGE

# Demo 54c — one kind cluster in this VM. kind talks to Colima via
# DOCKER_HOST (no `docker context use`). The kubeconfig is a file under
# $HOME so Desktop's ~/.kube/config is never rewritten.
#
# Address plan is this family's own (P4 / enhancement 008). The Desktop
# labs keep kind-eg 172.19.0.0/16 and EG VIPs 10.98.0.0/24; a Mac route
# for a prefix can point at one VM only.
KIND_EG_COLIMA_NET="${KIND_EG_COLIMA_NET:-kind-eg-colima}"
KIND_EG_COLIMA_SUBNET="${KIND_EG_COLIMA_SUBNET:-172.20.0.0/16}"
KIND_EG_COLIMA_IP_RANGE="${KIND_EG_COLIMA_IP_RANGE:-172.20.0.0/17}"
KIND_EG_COLIMA_GATEWAY="${KIND_EG_COLIMA_GATEWAY:-172.20.0.1}"
KIND_EG_COLIMA_LEAF1="${KIND_EG_COLIMA_LEAF1:-172.20.254.11}"
KIND_EG_COLIMA_LEAF2="${KIND_EG_COLIMA_LEAF2:-172.20.254.12}"
EG_COLIMA_VIP_BLOCK="${EG_COLIMA_VIP_BLOCK:-10.198.0.0/24}"
EG_COLIMA_DOOR="${EG_COLIMA_DOOR:-10.198.0.10}"
EG_COLIMA_CLUSTER="${EG_COLIMA_CLUSTER:-eg-poc1-colima}"
EG_COLIMA_KUBECONFIG="${EG_COLIMA_KUBECONFIG:-$HOME/.kube/config-eg-poc1-colima}"
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-kind-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"

# Refuse before the first docker daemon call. desktop-linux / default / md5lab
# never reach `docker --context` — the name check is the whole point.
fabric_colima_refuse_wrong_ctx() {
  case "$CTX" in
    desktop-linux|default)
      echo "fabric-colima: refusing to run against Docker Desktop (CTX=$CTX)." >&2
      echo "This demo talks only to docker --context colima-bgp-fabric (Colima profile bgp-fabric)." >&2
      echo "The Desktop fabric (project bgp-fabric, port 8088) and the kind clusters are off-limits." >&2
      return 1
      ;;
    colima-md5lab)
      echo "fabric-colima: refusing to touch the md5lab profile (CTX=$CTX)." >&2
      return 1
      ;;
    colima-bgp-fabric) ;;
    *)
      echo "fabric-colima: refusing CTX=$CTX (expected colima-bgp-fabric)." >&2
      echo "The Desktop fabric (bgp-fabric:8088), md5lab, kind and CRC are off-limits." >&2
      return 1
      ;;
  esac
  return 0
}

# Context exists and its VM answers. Used by every script except the start
# path in fabric-colima-up.sh (which creates the profile first).
fabric_colima_require_ctx() {
  fabric_colima_refuse_wrong_ctx || return 1
  if ! docker context inspect "$CTX" >/dev/null 2>&1; then
    echo "fabric-colima: docker context $CTX does not exist." >&2
    echo "Create and start the Colima profile: scripts/fabric-colima-up.sh" >&2
    return 1
  fi
  if ! docker --context "$CTX" info >/dev/null 2>&1; then
    echo "fabric-colima: docker context $CTX exists but its VM is not running." >&2
    echo "Start it: colima start --profile $FABRIC_COLIMA_PROFILE" >&2
    return 1
  fi
  return 0
}

# Every daemon call. Callers must have passed fabric_colima_require_ctx
# (or just created the profile) so this never targets Desktop.
dk() {
  docker --context "$CTX" "$@"
}

fabric_colima_compose() {
  dk compose -p "$FABRIC_COLIMA_PROJECT" -f "$FABRIC_COLIMA_FABRIC/compose.yaml" "$@"
}

# Same project, plus the kind-eg-colima overlay (leaves at 172.20.254.11/.12).
# Callers that attach the cluster LAN use this; fabric-only scripts stay
# on fabric_colima_compose so a missing overlay file cannot break them.
fabric_colima_compose_lan() {
  dk compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" "$@"
}

# kind and kubectl for the Colima cluster. DOCKER_HOST is the context's
# daemon — kind has no --docker-context flag. KUBECONFIG is a dedicated
# file so Desktop's kind-eg-poc1 context is not rewritten.
fabric_colima_kind_env() {
  local host
  host=$(docker context inspect "$CTX" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
  if [ -z "$host" ]; then
    echo "fabric-colima: cannot read Docker host for context $CTX" >&2
    return 1
  fi
  export DOCKER_HOST="$host"
  export KIND_EXPERIMENTAL_DOCKER_NETWORK="${KIND_EXPERIMENTAL_DOCKER_NETWORK:-$KIND_EG_COLIMA_NET}"
  export KUBECONFIG="${KUBECONFIG:-$EG_COLIMA_KUBECONFIG}"
}

# Node LAN for the Colima family. Docker IPAM is held to the lower /17
# so .254/24 (routers) and .255/24 (L2 VIP blocks) are never node addresses.
fabric_colima_ensure_kind_net() {
  local name="${KIND_EG_COLIMA_NET}"
  local subnet="${KIND_EG_COLIMA_SUBNET}"
  local ip_range="${KIND_EG_COLIMA_IP_RANGE}"
  local gateway="${KIND_EG_COLIMA_GATEWAY}"
  local have mtu
  if dk network inspect "$name" >/dev/null 2>&1; then
    have=$(dk network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' \
      | tr ' ' '\n' | grep -m1 '\.')
    if [ "$have" != "$subnet" ]; then
      echo "fabric-colima: network $name has subnet $have, not $subnet" >&2
      return 1
    fi
    echo "network $name exists with $have, kept"
    return 0
  fi
  mtu=$(dk network inspect bridge --format '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null) || true
  [ -n "${mtu:-}" ] || mtu=1500
  dk network create -d bridge \
    --subnet "$subnet" --ip-range "$ip_range" --gateway "$gateway" \
    -o com.docker.network.bridge.enable_ip_masquerade=true \
    -o com.docker.network.driver.mtu="$mtu" \
    "$name"
  echo "created $name: $(dk network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')"
}

# The VM's reachable address — Lima's vzNAT interface (col0), present only
# when the profile runs with network.address (`colima start --network-address`).
# Empty when it does not: then NO Mac route can reach this VM. Measured
# 2026-09-20: 192.168.64.3 belongs to the md5lab profile, not to bgp-fabric,
# whose profile had been created without the flag (eth0 192.168.5.3 only).
fabric_colima_vm_address() {
  colima list --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    if d.get("name") == want:
        print(d.get("address") or "")
        break
' "$FABRIC_COLIMA_PROFILE"
}

# The Linux bridge behind the node LAN (Docker names it br-<12 hex of the
# network id>), for the VM's own iptables rules.
fabric_colima_kind_bridge() {
  local id
  id=$(dk network inspect "$KIND_EG_COLIMA_NET" --format '{{.Id}}' 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  printf 'br-%s\n' "${id:0:12}"
}

# colima start --activate (the default) switches the active docker context.
# Restore the caller's context on EXIT, always — a leftover colima-bgp-fabric
# context orphans the Desktop lab (measured 2026-09-20).
fabric_colima_save_ctx() {
  FABRIC_COLIMA_PREV_CTX=$(docker context show 2>/dev/null || true)
}

fabric_colima_restore_ctx() {
  local now
  [ -n "${FABRIC_COLIMA_PREV_CTX:-}" ] || return 0
  now=$(docker context show 2>/dev/null || true)
  if [ -n "$now" ] && [ "$now" != "$FABRIC_COLIMA_PREV_CTX" ]; then
    docker context use "$FABRIC_COLIMA_PREV_CTX" >/dev/null 2>&1 || \
      echo "fabric-colima: WARNING could not restore docker context $FABRIC_COLIMA_PREV_CTX (now $now)" >&2
  fi
}
