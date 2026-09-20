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
