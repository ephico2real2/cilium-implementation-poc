#!/usr/bin/env bash
# apply.sh — demo 46: bring the fabric up with the Envoy overlay and record
# the sessions, the routes, and the SERVERS policy. Idempotent.
#   demos/55-bgp-fabric-desktop/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/55-bgp-fabric-desktop
FABRIC=$HERE/fabric
PROJECT=bgp-fabric
TRANSCRIPT=$HERE/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 46 apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

COMPOSE_ARGS=(-p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml")

echo "== 1. fabric-up.sh eg"
scripts/fabric-up.sh eg

echo "== 2. docker compose ps"
rec docker compose "${COMPOSE_ARGS[@]}" ps

echo "== 3. four show bgp summary"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp summary'

echo "== 4. show ip bgp on spine and edge"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show ip bgp'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show ip bgp'

echo "== 5. show ip route on edge"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show ip route'

echo "== 6. client0 traceroute and ping to leaf1 loopback"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 traceroute -n 10.200.255.11
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ping -c 3 -W 2 10.200.255.11

echo "== 7. client0 ip route"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ip route

# Which node a leaf must reach on the LAN. A single hardcoded address assumes
# a cluster shape: the recorded run had a node at 172.19.0.3, and a one-node
# cluster puts its only node on .2 (measured on a CI runner, 2026-09-23 — this
# step was the first thing in the whole apply that a different machine could
# not satisfy). The recorded address is preferred when it is actually on the
# LAN, so a local re-run reproduces the recorded line exactly; otherwise the
# first node there is used and named. FABRIC_NODE_PROBE overrides both.
node_on_lan() {
  docker network inspect kind-eg \
    --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
    | awk 'NF {split($2, a, "/"); print a[1]}'
}
NODE_PROBE="${FABRIC_NODE_PROBE:-}"
if [ -z "$NODE_PROBE" ]; then
  if node_on_lan | grep -qx 172.19.0.3; then
    NODE_PROBE=172.19.0.3
  else
    NODE_PROBE=$(node_on_lan | head -1)
  fi
fi
if [ -z "$NODE_PROBE" ]; then
  echo "apply: no node on kind-eg to probe — is a cluster up on it?" >&2
  exit 1
fi
echo "== 8. leaf1 ping $NODE_PROBE (kind-eg node, on-link)"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 ping -c 1 -W 2 "$NODE_PROBE"

echo "== 9. SERVERS group, listen range, prefix-lists, route-maps"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp listen'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show ip prefix-list'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show route-map'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp peer-group SERVERS'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show ip prefix-list'

# 10–12 are the live dashboard (phase 2). Existing 1–9 stay as they are.
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
# shellcheck disable=SC1091
. demos/shared/browser-shot.sh
SHOTDIR=$HERE/output/screenshots
mkdir -p "$SHOTDIR"

echo "== 10. dashboard /api/state"
rec curl -sS --max-time 5 http://127.0.0.1:8088/api/state
# shellcheck disable=SC2329
state_head() {
  curl -sS --max-time 5 http://127.0.0.1:8088/api/state | python3 -m json.tool | head -60
}
export -f state_head
rec bash -c state_head
unset -f state_head
rec bash -c 'curl -fsS --max-time 5 http://127.0.0.1:8088/api/state | python3 scripts/fabric-dashboard-state.py'

echo "== 11. screenshot, steady"
# shellcheck disable=SC2329
shot_steady() {
  BROWSER_SHOT_PATH="$PWD/$HERE/output/screenshots/dashboard-steady.png"
  BROWSER_SHOT_URL="http://127.0.0.1:8088/?router=spine"
  BROWSER_SHOT_WIDTH=1200
  BROWSER_SHOT_HEIGHT=700
  BROWSER_SHOT_VIRTUAL_TIME_MS=4000
  BROWSER_SHOT_FILE_LABEL="$HERE/output/screenshots/dashboard-steady.png"
  browser_shot
}
export -f shot_steady browser_shot
export CHROME HERE BROWSER_SHOT_PATH BROWSER_SHOT_URL BROWSER_SHOT_WIDTH BROWSER_SHOT_HEIGHT BROWSER_SHOT_VIRTUAL_TIME_MS BROWSER_SHOT_FILE_LABEL
rec bash -c shot_steady
unset -f shot_steady

echo "== 12. clear bgp * on spine, events, recovery shots"
# shellcheck disable=SC2329
clear_and_watch() {
  set -euo pipefail
  # Mark the event log BEFORE the clear: the fabric's start-up Established
  # events are already in it, so `since=0` would call the recovery done at once.
  mark=$(curl -fsS --max-time 3 'http://127.0.0.1:8088/api/events?since=0' \
    | python3 -c 'import json,sys; ev=json.load(sys.stdin); print(ev[-1]["id"] if ev else 0)')
  echo "event mark before clear: id=$mark"
  docker compose -p bgp-fabric -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
    -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
    exec -T spine vtysh -c 'clear bgp *'
  echo "clear bgp * issued on spine"
  drop_start=$(python3 -c 'import time; print("%.6f" % time.time())')
  showed=""
  drop_i=0
  while [ "$drop_i" -lt 60 ]; do
    st=$(curl -fsS --max-time 2 http://127.0.0.1:8088/api/state 2>/dev/null || true)
    if printf '%s' "$st" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
except json.JSONDecodeError:
    raise SystemExit(1)
for e in data.get("edges") or []:
    if not isinstance(e, dict):
        continue
    if str(e.get("state") or "").lower() != "established":
        raise SystemExit(0)
raise SystemExit(1)
'; then
      showed=1
      break
    fi
    drop_i=$((drop_i + 1))
    sleep 0.25
  done
  drop_elapsed=$(DROP_START="$drop_start" python3 -c 'import os,time; print("%.2f" % (time.time() - float(os.environ["DROP_START"])))')
  if [ -n "$showed" ]; then
    echo "dashboard showed the drop after ${drop_elapsed} s"
  else
    echo "dashboard never showed a non-established edge within 15 s"
  fi
  BROWSER_SHOT_PATH="$PWD/$HERE/output/screenshots/dashboard-clear-bgp.png"
  BROWSER_SHOT_URL="http://127.0.0.1:8088/?router=spine"
  BROWSER_SHOT_WIDTH=1200
  BROWSER_SHOT_HEIGHT=700
  BROWSER_SHOT_VIRTUAL_TIME_MS=4000
  BROWSER_SHOT_FILE_LABEL="$HERE/output/screenshots/dashboard-clear-bgp.png"
  browser_shot
  rec_start=$(python3 -c 'import time; print("%.6f" % time.time())')
  recovered=""
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ev=$(curl -fsS --max-time 2 "http://127.0.0.1:8088/api/events?since=$mark" || true)
    st=$(curl -fsS --max-time 2 http://127.0.0.1:8088/api/state || true)
    if printf '%s' "$st" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
except json.JSONDecodeError:
    raise SystemExit(1)
edges = [e for e in (data.get("edges") or []) if isinstance(e, dict)]
if not edges:
    raise SystemExit(1)
for e in edges:
    if str(e.get("state") or "").lower() != "established":
        raise SystemExit(1)
raise SystemExit(0)
' && printf '%s' "$ev" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    raise SystemExit(1)
for e in data:
    if not isinstance(e, dict):
        continue
    if e.get("kind") == "session" and e.get("router") == "spine" and e.get("to") == "Established":
        raise SystemExit(0)
raise SystemExit(1)
'; then
      recovered=1
      break
    fi
    sleep 0.25
  done
  rec_elapsed=$(REC_START="$rec_start" python3 -c 'import os,time; print("%.2f" % (time.time() - float(os.environ["REC_START"])))')
  # rec_start is taken AFTER the drop screenshot (~1.4 s of Chrome), so this
  # is the time the poll loop needed to NOTICE a recovery, not the recovery
  # itself: the event window (first Idle → last Established) is printed below.
  if [ -n "$recovered" ]; then
    echo "dashboard confirmed recovery after ${rec_elapsed} s (polled after the screenshots)"
  else
    echo "dashboard: no spine to=Established event within 60 s"
  fi
  BROWSER_SHOT_PATH="$PWD/$HERE/output/screenshots/dashboard-recovered.png"
  BROWSER_SHOT_FILE_LABEL="$HERE/output/screenshots/dashboard-recovered.png"
  browser_shot
  MARK="$mark" python3 - <<'PY'
import json, os, urllib.request
raw = urllib.request.urlopen("http://127.0.0.1:8088/api/events?since=%s" % os.environ["MARK"], timeout=3).read()
ev = json.loads(raw)
print("events after the clear: %d" % len(ev))
print("ts\tkind\trouter\tpeer\tprefix\tfrom→to\ttext")
for e in ev[-30:]:
    print("%s\t%s\t%s\t%s\t%s\t%s→%s\t%s" % (
        e.get("ts",""), e.get("kind",""), e.get("router",""),
        e.get("peer",""), e.get("prefix",""),
        e.get("from",""), e.get("to",""), e.get("text","")))
spine = [e for e in ev if e.get("kind")=="session" and e.get("router")=="spine"]
idle = next((e for e in spine if e.get("to")=="Idle"), None)
last_up = None
for e in spine:
    if e.get("to") == "Established":
        last_up = e
first_idle_ts = idle.get("ts") if idle else None
last_up_ts = last_up.get("ts") if last_up else None
# the recovery a reader means: from the first spine session going Idle to the
# last one back to Established, on the dashboard's own event stamps
window = ""
if first_idle_ts and last_up_ts:
    import datetime
    fmt = "%Y-%m-%dT%H:%M:%S.%fZ"
    window = " window=%.3f s" % (
        datetime.datetime.strptime(last_up_ts, fmt) - datetime.datetime.strptime(first_idle_ts, fmt)
    ).total_seconds()
print("spine recovery: first Idle %s last Established %s recovered=%s%s" % (
    first_idle_ts, last_up_ts, "yes" if last_up else "no", window))
PY
}
export -f clear_and_watch browser_shot
export CHROME HERE
rec bash -c clear_and_watch
unset -f clear_and_watch browser_shot

echo "dashboard: http://127.0.0.1:8088/ (Mac browser)"
echo "demo 46 apply: recorded"
