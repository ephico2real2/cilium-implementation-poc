#!/usr/bin/env bash
# fabric-up.sh — bring up the company BGP fabric (demo 46).
#   scripts/fabric-up.sh                 # compose.yaml only
#   scripts/fabric-up.sh eg              # + compose.lan-eg.yaml (kind-eg)
#   scripts/fabric-up.sh cilium          # + compose.lan-cilium.yaml (kind)
#   scripts/fabric-up.sh eg,cilium       # both overlays
# Idempotent. Linux-runner safe. Every step through scripts/record.sh
# (RECORD_STRICT=1) into demos/46-bgp-fabric/output/transcript.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.3}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"

FABRIC=demos/46-bgp-fabric/fabric
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
TRANSCRIPT="${FABRIC_TRANSCRIPT:-demos/46-bgp-fabric/output/transcript.txt}"
DEADLINE="${FABRIC_CONVERGE_SECS:-60}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"

# shellcheck disable=SC1091
if [ -f "$FABRIC/.env" ]; then
  set -a
  . "$FABRIC/.env"
  set +a
fi
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

usage() {
  echo "usage: $0 [eg|cilium|eg,cilium]" >&2
}

want_eg=0
want_cilium=0
if [ $# -gt 1 ]; then
  usage
  exit 2
fi
if [ $# -eq 1 ]; then
  case "$1" in
    eg) want_eg=1 ;;
    cilium) want_cilium=1 ;;
    eg,cilium|cilium,eg) want_eg=1; want_cilium=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
fi

COMPOSE_ARGS=(-p "$PROJECT" -f "$FABRIC/compose.yaml")
if [ "$want_eg" -eq 1 ]; then
  COMPOSE_ARGS+=(-f "$FABRIC/compose.lan-eg.yaml")
fi
if [ "$want_cilium" -eq 1 ]; then
  COMPOSE_ARGS+=(-f "$FABRIC/compose.lan-cilium.yaml")
fi

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
printf '\n### %s — fabric-up project=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROJECT" >>"$TRANSCRIPT"

say() { echo "== $*"; }

say "1. docker compose up -d --wait (project $PROJECT)"
rec docker compose "${COMPOSE_ARGS[@]}" up -d --wait

compose_exec() { # service args…
  local svc=$1
  shift
  docker compose "${COMPOSE_ARGS[@]}" exec -T "$svc" "$@"
}

vtysh_json() { # service
  compose_exec "$1" vtysh -c 'show bgp summary json'
}

require_sessions() {
  local svc=$1
  shift
  local raw rc=0
  raw=$(vtysh_json "$svc") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    echo "fabric-up: vtysh json failed on $svc rc=$rc" >&2
    return 1
  fi
  printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$@"
}

say "2. wait for the six fabric sessions (deadline ${DEADLINE}s)"
start=$(date +%s)
ok=0
while :; do
  if require_sessions edge 10.200.1.18 \
     && require_sessions spine 10.200.1.2 10.200.1.10 10.200.1.19 \
     && require_sessions leaf1 10.200.1.3 \
     && require_sessions leaf2 10.200.1.11; then
    ok=1
    break
  fi
  now=$(date +%s)
  if [ $((now - start)) -ge "$DEADLINE" ]; then
    break
  fi
  sleep 2
done
elapsed=$(( $(date +%s) - start ))
if [ "$ok" -ne 1 ]; then
  echo "fabric-up: fabric sessions not Established after ${elapsed}s" >&2
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp summary'
  exit 1
fi
echo "fabric-up: sessions Established after ${elapsed}s"

say "3. show bgp summary json on all four (every fabric session Established)"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show bgp summary json'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show bgp summary json'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp summary json'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp summary json'

say "4. loopbacks from client0 (10.200.255.11 and .12)"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ping -c 1 -W 2 10.200.255.11
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ping -c 1 -W 2 10.200.255.12

say "5. client0 path"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ip route

echo "fabric-up: ready (project $PROJECT, ${elapsed}s to Established)"
