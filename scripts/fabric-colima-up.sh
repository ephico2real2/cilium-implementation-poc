#!/usr/bin/env bash
# fabric-colima-up.sh — create the bgp-fabric Colima profile if absent, build
# the :colima images in that VM, and bring up project bgp-fabric-colima.
# Fabric alone: no kind overlay (kind-eg lives on Docker Desktop).
#
# Hard constraints from the operator's Colima guide (recorded so nobody
# "fixes" them later):
#   - vmType and mountType cannot be changed after the VM is created
#   - disk can only grow, never shrink
# Inherited host DNS breaks on VPN/split-DNS — pin 8.8.8.8 / 8.8.4.4.
#
# Every docker call is `docker --context "$CTX"` (default colima-bgp-fabric).
# colima start --activate (the default) switches the active context; this
# script always restores the previous one (EXIT trap) because a leftover
# switch orphans the Desktop lab — measured 2026-09-20.
#
# Bind mounts: Colima only shares what Lima mounts. $HOME is virtiofs-
# mounted; /var/folders is not. A mktemp -d config directory fails with
# "not a directory" on the bind (measured 2026-09-20). This script binds
# only from the repo (under $HOME).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.7.1}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_ROUTER_IMAGE="$FABRIC_COLIMA_ROUTER_IMAGE"
export FABRIC_DASHBOARD_IMAGE="$FABRIC_COLIMA_DASHBOARD_IMAGE"
export FABRIC_COLIMA_DASHBOARD_PORT

TRANSCRIPT="${FABRIC_TRANSCRIPT:-$FABRIC_COLIMA_HERE/output/transcript.txt}"
DEADLINE="${FABRIC_CONVERGE_SECS:-60}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi

fabric_colima_save_ctx
trap fabric_colima_restore_ctx EXIT

# Create the profile only when Lima has no directory for it. Re-passing
# --vm-type / --mount-type on an existing VM is refused (they are frozen).
profile_dir="${HOME}/.colima/${FABRIC_COLIMA_PROFILE}"
if [ ! -d "$profile_dir" ]; then
  echo "== 0. colima start --profile $FABRIC_COLIMA_PROFILE (create)"
  # --activate=false: do not steal the caller's docker context. The trap
  # still restores in case a colima version ignores the flag.
  colima start --profile "$FABRIC_COLIMA_PROFILE" \
    --vm-type vz \
    --mount-type virtiofs \
    --mount-inotify \
    --cpu 4 \
    --memory 6 \
    --disk 40 \
    --dns 8.8.8.8 \
    --dns 8.8.4.4 \
    --activate=false
else
  echo "== 0. colima start --profile $FABRIC_COLIMA_PROFILE (existing; vmType/mountType frozen, disk can only grow)"
  if ! colima status --profile "$FABRIC_COLIMA_PROFILE" >/dev/null 2>&1; then
    colima start --profile "$FABRIC_COLIMA_PROFILE" --activate=false
  fi
fi

if ! fabric_colima_require_ctx; then
  exit 1
fi

if [ ! -f "$FABRIC_COLIMA_FABRIC/.env" ] && [ -f "$FABRIC_COLIMA_FABRIC/.env.example" ]; then
  cp "$FABRIC_COLIMA_FABRIC/.env.example" "$FABRIC_COLIMA_FABRIC/.env"
fi
if [ -f "$FABRIC_COLIMA_FABRIC/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$FABRIC_COLIMA_FABRIC/.env"
  set +a
fi
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

# One fabric per Colima VM — the /29s overlap with any second copy *in this
# context*. Desktop's bgp-fabric is a different engine and is not visible.
while read -r net_id; do
  [ -n "$net_id" ] || continue
  subnet=$(dk network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$net_id" 2>/dev/null || true)
  printf '%s' "$subnet" | grep -qF '10.200.1.0/29' || continue
  proj=$(dk network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$net_id" 2>/dev/null || true)
  if [ -n "$proj" ] && [ "$proj" != "$FABRIC_COLIMA_PROJECT" ]; then
    echo "fabric-colima-up: one fabric per Colima VM — project $proj already owns 10.200.1.0/29" >&2
    exit 1
  fi
done < <(dk network ls -q 2>/dev/null || true)

port_holder=$(dk ps --filter "publish=${FABRIC_COLIMA_DASHBOARD_PORT}" \
  --format '{{.Names}}' 2>/dev/null | grep -v "^${FABRIC_COLIMA_PROJECT}-" | head -1 || true)
if [ -n "$port_holder" ]; then
  echo "fabric-colima-up: 127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT} is published by container $port_holder (not this project)" >&2
  exit 1
fi

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
printf '\n### %s — fabric-colima-up project=%s ctx=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FABRIC_COLIMA_PROJECT" "$CTX" >>"$TRANSCRIPT"

say() { echo "== $*"; }

need_image() {
  if [ "${FABRIC_REBUILD:-0}" = 1 ]; then
    return 0
  fi
  ! dk image inspect "$1" >/dev/null 2>&1
}

say "1. local images ($FABRIC_ROUTER_IMAGE, $FABRIC_DASHBOARD_IMAGE) via docker --context $CTX"
if need_image "$FABRIC_ROUTER_IMAGE"; then
  rec docker --context "$CTX" build -t "$FABRIC_ROUTER_IMAGE" --build-arg FRR_IMAGE="$FRR_IMAGE" \
    -f "$FABRIC_COLIMA_HERE/frr-agent/Containerfile" "$FABRIC_COLIMA_HERE/frr-agent"
else
  rec echo "image $FABRIC_ROUTER_IMAGE present"
fi
if need_image "$FABRIC_DASHBOARD_IMAGE"; then
  rec docker --context "$CTX" build -t "$FABRIC_DASHBOARD_IMAGE" \
    -f "$FABRIC_COLIMA_HERE/dashboard/Containerfile" "$FABRIC_COLIMA_HERE/dashboard"
else
  rec echo "image $FABRIC_DASHBOARD_IMAGE present"
fi

say "2. docker --context $CTX compose up -d --wait (project $FABRIC_COLIMA_PROJECT)"
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" up -d --wait

require_sessions() {
  local svc=$1
  shift
  local raw rc=0
  raw=$(fabric_colima_compose exec -T "$svc" vtysh -c 'show bgp summary json') || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    echo "fabric-colima-up: vtysh json failed on $svc rc=$rc" >&2
    return 1
  fi
  printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$@"
}

say "3. wait for the six fabric sessions (deadline ${DEADLINE}s)"
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
  echo "fabric-colima-up: fabric sessions not Established after ${elapsed}s" >&2
  rec echo "not converged after ${elapsed} s (${polls} polls)"
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T edge vtysh -c 'show bgp summary'
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T spine vtysh -c 'show bgp summary'
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T leaf1 vtysh -c 'show bgp summary'
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T leaf2 vtysh -c 'show bgp summary'
  exit 1
fi
rec echo "converged after ${elapsed} s (${polls} polls)"
echo "fabric-colima-up: sessions Established after ${elapsed}s"

say "4. show bgp summary json on all four"
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T edge vtysh -c 'show bgp summary json'
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T spine vtysh -c 'show bgp summary json'
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T leaf1 vtysh -c 'show bgp summary json'
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T leaf2 vtysh -c 'show bgp summary json'

say "5. loopbacks from client0"
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T client0 ping -c 1 -W 2 10.200.255.11
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T client0 ping -c 1 -W 2 10.200.255.12

say "6. client0 path"
rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" exec -T client0 ip route

say "7. dashboard healthz and 4/4 on 127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT} (deadline 60s)"
dash_start=$(date +%s)
dash_ok=0
dash_line=""
while :; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/healthz" >/dev/null 2>&1; then
    if dash_line=$(curl -fsS --max-time 2 "http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/api/state" \
         | python3 scripts/fabric-dashboard-state.py); then
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
  echo "fabric-colima-up: dashboard not ready after ${dash_elapsed}s" >&2
  rec echo "dashboard not ready after ${dash_elapsed} s (${dash_line:-no /api/state})"
  rec curl -sS --max-time 2 "http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/healthz" || true
  rec curl -sS --max-time 2 "http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}/api/state" || true
  exit 1
fi
rec echo "dashboard ready after ${dash_elapsed} s ($dash_line)"
echo "fabric-colima-up: dashboard ready after ${dash_elapsed}s ($dash_line)"

echo "fabric-colima-up: ready (project $FABRIC_COLIMA_PROJECT, ctx $CTX, ${elapsed}s to Established)"
