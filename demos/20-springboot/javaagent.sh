#!/usr/bin/env bash
# javaagent.sh on|off — attach (or detach) the OpenTelemetry Java agent to every petclinic Deployment.
#   on : patch each Deployment with 30-javaagent-patch.yaml, ONE AT A TIME (a patch is a rolling restart; six
#        cold JVMs at once would double the memory the VM has left — measured headroom ~1.8 GB)
#   off: delete the six Deployments and re-apply 10-petclinic.yaml (a strategic patch's additions — the init
#        container, the volume, the env — survive a plain re-apply, so this is the honest way back)
set -euo pipefail; cd "$(dirname "$0")/../.."; MODE="${1:-on}"; NS=springboot
DEPLOYS="config-server discovery-server customers-service vets-service visits-service api-gateway"
if [ "$MODE" = on ]; then
  for d in $DEPLOYS; do
    sed "s/__NAME__/$d/g" demos/20-springboot/30-javaagent-patch.yaml > .tmp/javaagent-$d.yaml
    kubectl --context kind-poc1 -n $NS patch deploy "$d" --type strategic --patch-file .tmp/javaagent-$d.yaml >/dev/null
    printf "  %-18s patched; " "$d"; kubectl --context kind-poc1 -n $NS rollout status deploy/$d --timeout=10m 2>&1 | tail -1
  done
elif [ "$MODE" = off ]; then
  kubectl --context kind-poc1 -n $NS delete deploy $DEPLOYS --wait=true
  kubectl --context kind-poc1 apply -f demos/20-springboot/10-petclinic.yaml >/dev/null
  for d in $DEPLOYS; do printf "  %-18s " "$d"; kubectl --context kind-poc1 -n $NS rollout status deploy/$d --timeout=10m 2>&1 | tail -1; done
else echo "usage: javaagent.sh on|off"; exit 2; fi
