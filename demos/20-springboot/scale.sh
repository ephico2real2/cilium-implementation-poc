#!/usr/bin/env bash
# scale.sh down|up — make room for the six petclinic JVMs on a 16 GB Docker VM, and give it back.
#   down: every Deployment in the bank (both clusters) and routes namespaces → 0 replicas. StatefulSets (postgres,
#         postgres-standby, redis) keep running: they hold the demo 15 ledger and the replication slot.
#   up:   the demo 15 / demo 09 replica counts again.
set -uo pipefail; MODE="${1:?usage: scale.sh down|up}"
case "$MODE" in
  down)
    kubectl --context kind-poc1 -n bank   scale deploy --all --replicas=0
    kubectl --context kind-poc2 -n bank   scale deploy --all --replicas=0
    kubectl --context kind-poc1 -n routes scale deploy --all --replicas=0 ;;
  up)
    kubectl --context kind-poc1 -n bank scale deploy api web --replicas=2 && kubectl --context kind-poc1 -n bank scale deploy payments --replicas=1
    kubectl --context kind-poc2 -n bank scale deploy accounts --replicas=2 && kubectl --context kind-poc2 -n bank scale deploy payments --replicas=1
    kubectl --context kind-poc1 -n routes scale deploy echo grpc web --replicas=2 ;;
  *) echo "usage: scale.sh down|up"; exit 2 ;;
esac
sleep 5; for c in poc1 poc2; do for ns in bank routes; do kubectl --context kind-$c get ns $ns >/dev/null 2>&1 || continue; echo "-- $c/$ns --"; kubectl --context kind-$c -n $ns get deploy -o custom-columns='DEPLOY:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas' --no-headers | sed 's/^/  /'; done; done
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -- sh -c 'free -m | awk "/Mem:/ {print \"VM available:\", \$7, \"MB\"}"; cut -d" " -f1-3 /proc/loadavg'
