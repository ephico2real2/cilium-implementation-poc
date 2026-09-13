#!/usr/bin/env bash
# cleanup.sh — nothing to undo: demo 33's end state IS the hardened one, and it is what values-hubble-observer.yaml
# commits (the subchart's policy, the allowed origin, the parent chart's entities narrowed; no token). The token was on
# for one Helm revision during Part 3 and is already off (revision 29). To go back to the open configuration, edit the
# three values in demos/25-hubble-observer-loki/values-hubble-observer.yaml and run chart-from-fork.sh again.
set -uo pipefail; cd "$(dirname "$0")/../.."
helm --kube-context kind-poc1 -n hubble-observer get values hubble-observer -o json | python3 -c '
import json,sys; v=json.load(sys.stdin)["cf2cnp"]
print("cors:", v["cors"], "| networkPolicy:", v["networkPolicy"], "| auth token set:", bool(v.get("auth",{}).get("token")))'
echo "nothing removed; the hardened state stays (see the header of this script)"
