#!/usr/bin/env bash
# cleanup.sh — remove the second observer release (the policy-verdict stream, E8). The first release, the collector's
# extra glob (harmless without the pod) and the dashboard's Loki row (chart 0.2.0, on since demo 29's values) stay:
# they are the committed state. output/ stays.
set -uo pipefail; cd "$(dirname "$0")/../.."
helm --kube-context kind-poc1 -n hubble-observer uninstall hubble-observer-verdicts 2>&1 | tail -1
echo "hubble-observer-verdicts uninstalled; the first release, the collector and the dashboard stay; output/ kept"
