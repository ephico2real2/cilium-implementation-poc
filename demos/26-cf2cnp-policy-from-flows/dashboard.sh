#!/usr/bin/env bash
# dashboard.sh — provision demo 26's "Hubble / Policy Verdicts (Namespace)" dashboard the way demo 16 provisions every
# dashboard: a ConfigMap in `monitoring` carrying the JSON, labelled grafana_dashboard=1 so the kube-prometheus-stack
# sidecar loads it, with the grafana_folder annotation placing it in the Hubble folder next to the chart's own.
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 -n monitoring create configmap hubble-policy-verdicts-dashboard \
  --from-file=hubble-policy-verdicts.json=demos/26-cf2cnp-policy-from-flows/30-policy-verdicts-dashboard.json --dry-run=client -o yaml \
 | kubectl --context kind-poc1 label --local -f - grafana_dashboard=1 --dry-run=client -o yaml \
 | kubectl --context kind-poc1 annotate --local -f - grafana_folder=Hubble --dry-run=client -o yaml \
 | kubectl --context kind-poc1 apply -f -
# The check goes through Grafana's API: the grafana container image has no shell (`exec … sh` fails with "executable
# file not found"), so the sidecar's /tmp/dashboards folder cannot be listed from outside — measured the first time.
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
echo "waiting for the sidecar to load it (its log says where it placed the file)…"; for i in $(seq 1 24); do sleep 5
  if curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana "https://grafana.poc.local/api/dashboards/uid/policy-verdicts-26" | grep -q '"folderTitle":"Hubble"'; then
    kubectl --context kind-poc1 -n monitoring logs deploy/monitoring-grafana -c grafana-sc-dashboard --since=10m 2>/dev/null | grep "hubble-policy-verdicts" | tail -1 | sed 's/^/  sidecar: /'
    echo "loaded in folder Hubble → https://grafana.poc.local/d/policy-verdicts-26"; exit 0; fi; done
echo "not in Grafana after 2 min" >&2; exit 1
