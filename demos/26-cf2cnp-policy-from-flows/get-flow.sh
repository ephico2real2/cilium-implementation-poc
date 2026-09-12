#!/usr/bin/env bash
# get-flow.sh <source> [args] — obtain ONE Hubble flow as the JSON cf2cnp expects, from any place this stack keeps flows.
#   get-flow.sh cli   <hubble observe filters…>     the Hubble CLI against the relay (the live ring buffer: seconds of history)
#   get-flow.sh observer [grep]                     the hubble-observer pod's stdout (DROPPED flows only — that is its filter)
#   get-flow.sh loki  '<LogQL selector>' [minutes]  Loki through the API (the stored history: hours, both clusters)
#   get-flow.sh export <node> [grep]                Hubble's flow-export file on a node (demo 10; poc1 nodes only)
# One JSON object on stdout, envelope {"flow": {...}, "node_name": ..., "time": ...}. For `cli`, the CLI's own config
# carries the relay's TLS settings (demo 25 Part 5g: `scripts/hubble-tls.sh --configure`), the last 30 flows are read
# and the first that is a request (not a reply) is returned. Filter rules that matter: --from-pod/--to-pod/--pod
# already name the namespace and cannot be combined with --namespace; --traffic-direction ingress|egress selects which
# side reported the flow — cf2cnp writes an INGRESS policy for the destination from an ingress flow and an EGRESS policy
# for the source from an egress flow.
set -uo pipefail; cd "$(dirname "$0")/../.."; SRC="${1:?source}"; shift
case "$SRC" in
  cli)      hubble observe -P --kube-context kind-poc1 "$@" --last 30 -o json 2>/dev/null | python3 -c '
import json,sys
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try: d=json.loads(l)
    except Exception: continue
    if d.get("flow",{}).get("is_reply"): continue
    print(l); break' ;;
  observer) kubectl --context kind-poc1 -n hubble-observer logs deploy/hubble-observer -c hubble-observer --since=30m 2>/dev/null | grep -- "${1:-.}" | tail -1 ;;
  loki)     SEL="${1:?LogQL selector}"; MIN="${2:-60}"; NOW=$(date +%s); Q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$SEL")
            kubectl --context kind-poc1 get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query_range?query=$Q&start=$((NOW-MIN*60))000000000&end=${NOW}000000000&limit=1&direction=backward" \
              | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["values"][0][1] if r and r[0]["values"] else "")' ;;
  export)   NODE="${1:?node}"; docker exec "$NODE" sh -c "grep -- '${2:-.}' /var/run/cilium/hubble/events.log 2>/dev/null | tail -1" ;;
  *) echo "usage: get-flow.sh cli|observer|loki|export …" >&2; exit 2 ;;
esac
