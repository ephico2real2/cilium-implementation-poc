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
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.7.1}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_ROUTER_IMAGE="${FABRIC_ROUTER_IMAGE:-frr-agent:local}"
export FABRIC_DASHBOARD_IMAGE="${FABRIC_DASHBOARD_IMAGE:-bgp-dashboard:local}"

FABRIC=demos/46-bgp-fabric/fabric
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
TRANSCRIPT="${FABRIC_TRANSCRIPT:-demos/46-bgp-fabric/output/transcript.txt}"
DEADLINE="${FABRIC_CONVERGE_SECS:-60}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"

# shellcheck disable=SC1091
if [ ! -f "$FABRIC/.env" ] && [ -f "$FABRIC/.env.example" ]; then
  cp "$FABRIC/.env.example" "$FABRIC/.env"
fi
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

# One fabric per Docker host — the /29 link subnets overlap with any second copy.
while read -r net_id; do
  [ -n "$net_id" ] || continue
  subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$net_id" 2>/dev/null || true)
  printf '%s' "$subnet" | grep -qF '10.200.1.0/29' || continue
  proj=$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$net_id" 2>/dev/null || true)
  if [ -n "$proj" ] && [ "$proj" != "$PROJECT" ]; then
    echo "fabric-up: one fabric per Docker host — the /29 link subnets overlap with any second copy (project $proj already owns 10.200.1.0/29)" >&2
    exit 1
  fi
done < <(docker network ls -q 2>/dev/null || true)

# The dashboard publishes 127.0.0.1:8088. Another project holding it takes the
# fabric's dashboard down mid-run: measured 2026-09-20, a second lab on this host
# published the same port and bgp-fabric-dashboard-1 exited (code 2, one log line)
# while demo 46 was recording. Name the holder and stop, rather than half-start.
port_holder=$(docker ps --filter "publish=${FABRIC_DASHBOARD_PORT:-8088}" \
  --format '{{.Names}}' 2>/dev/null | grep -v "^${PROJECT}-" | head -1 || true)
if [ -n "$port_holder" ]; then
  echo "fabric-up: 127.0.0.1:${FABRIC_DASHBOARD_PORT:-8088} is published by container $port_holder (not this project) — stop it, or set FABRIC_DASHBOARD_PORT" >&2
  exit 1
fi

# The fabric, the dashboard and the agent come from the bgp-fabric repository
# at a pinned commit (scripts/bgp-fabric.env), not from a copy in this tree.
BGP_FABRIC=$(scripts/bgp-fabric-fetch.sh)
export BGP_FABRIC

# The image is stamped with the commit it was built from, and the stamp is
# COMPUTED, never typed: a hand-passed sha is an assertion nobody checks, and
# the page then names a commit that does not contain the code it is serving
# (measured 2026-09-23 — the lab served `build 4cf1864`, a commit with neither
# the endpoint nor the label function in its tree). A dirty tree keeps its
# `-dirty` marker.
#
# The revision asked for is bgp-fabric's, not this repository's: the dashboard
# source lives there now, so a sha from here would name a commit whose tree
# does not contain the code being built — the very mistake the stamp exists to
# catch.
IFS=$'\t' read -r REVISION BUILT < <("$BGP_FABRIC/scripts/build-revision.sh")
export REVISION BUILT

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
printf '\n### %s — fabric-up project=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROJECT" >>"$TRANSCRIPT"

say() { echo "== $*"; }

need_image() { # tag — 0 if we should build
  if [ "${FABRIC_REBUILD:-0}" = 1 ]; then
    return 0
  fi
  ! docker image inspect "$1" >/dev/null 2>&1
}

say "0. local images ($FABRIC_ROUTER_IMAGE, $FABRIC_DASHBOARD_IMAGE)"
if need_image "$FABRIC_ROUTER_IMAGE"; then
  rec docker build -t "$FABRIC_ROUTER_IMAGE" --build-arg FRR_IMAGE="$FRR_IMAGE" \
    -f "$BGP_FABRIC/frr-agent/Containerfile" "$BGP_FABRIC/frr-agent"
else
  rec echo "image $FABRIC_ROUTER_IMAGE present"
fi
if need_image "$FABRIC_DASHBOARD_IMAGE"; then
  rec docker build -t "$FABRIC_DASHBOARD_IMAGE" \
    --build-arg REVISION="$REVISION" --build-arg BUILT="$BUILT" \
    -f "$BGP_FABRIC/dashboard/Containerfile" "$BGP_FABRIC/dashboard"
else
  rec echo "image $FABRIC_DASHBOARD_IMAGE present"
fi

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
polls=0
while :; do
  polls=$((polls + 1))
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
  rec echo "not converged after ${elapsed} s (${polls} polls)"
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
  rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp summary'
  exit 1
fi
rec echo "converged after ${elapsed} s (${polls} polls)"
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

say "6. dashboard healthz and 4/4 (deadline 60s)"
dash_start=$(date +%s)
dash_ok=0
dash_line=""
while :; do
  if curl -fsS --max-time 2 http://127.0.0.1:8088/healthz >/dev/null 2>&1; then
    if dash_line=$(curl -fsS --max-time 2 http://127.0.0.1:8088/api/state | python3 scripts/fabric-dashboard-state.py); then
      dash_ok=1
      break
    fi
  fi
  now=$(date +%s)
  if [ $((now - dash_start)) -ge 60 ]; then
    break
  fi
  sleep 1
done
dash_elapsed=$(( $(date +%s) - dash_start ))
if [ "$dash_ok" -ne 1 ]; then
  echo "fabric-up: dashboard not ready after ${dash_elapsed}s" >&2
  rec echo "dashboard not ready after ${dash_elapsed} s (${dash_line:-no /api/state})"
  rec curl -sS --max-time 2 http://127.0.0.1:8088/healthz || true
  rec curl -sS --max-time 2 http://127.0.0.1:8088/api/state || true
  exit 1
fi
rec echo "dashboard ready after ${dash_elapsed} s ($dash_line)"
echo "fabric-up: dashboard ready after ${dash_elapsed}s ($dash_line)"

echo "fabric-up: ready (project $PROJECT, ${elapsed}s to Established)"
