#!/usr/bin/env bash
# dashboard-configmap.sh <grafana.com id> <namespace> <configmap-name> <uid> [title suffix] [folder]
#   Turn a grafana.com dashboard into a ConfigMap the demo 16 Grafana sidecar provisions — the exact steps demo 20
#   used for "Spring Boot 3.x Statistics" (id 19004). Prints the ConfigMap as JSON to stdout (kubectl apply -f - reads JSON as it reads YAML); pipe to kubectl apply.
#   1. download the latest revision's JSON from grafana.com's API
#   2. resolve the import-time placeholder ${DS_PROMETHEUS} to the live Prometheus datasource uid (the sidecar does
#      no import-time input resolution — an unresolved placeholder renders empty panels)
#   3. drop __inputs/__requires, clear the numeric id, pin a stable uid (the URL) and a title suffix
#   4. wrap it in a ConfigMap labelled grafana_dashboard=1 (the label Section A's values told the sidecar to watch,
#      in ANY namespace: searchNamespace ALL) with an optional grafana_folder annotation
# Example (demo 20):
#   demos/16-monitoring/dashboard-configmap.sh 19004 springboot grafana-dashboard-springboot springboot-19004 " (petclinic)" "Spring Boot" \
#     | kubectl --context kind-poc1 apply -f -
set -euo pipefail
ID="${1:?grafana.com dashboard id}"; NS="${2:?namespace}"; NAME="${3:?configmap name}"; UID_="${4:?dashboard uid}"; SUFFIX="${5:-}"; FOLDER="${6:-}"
CTX="${CTX:-kind-poc1}"; cd "$(dirname "$0")/../.."
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
DSUID=$(curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana https://grafana.poc.local/api/datasources \
        | python3 -c 'import json,sys; print(next(d["uid"] for d in json.load(sys.stdin) if d["type"]=="prometheus"))')
curl -sL "https://grafana.com/api/dashboards/${ID}/revisions/latest/download" \
 | DSUID="$DSUID" UID_="$UID_" SUFFIX="$SUFFIX" NS="$NS" NAME="$NAME" FOLDER="$FOLDER" python3 -c '
import json,os,sys   # JSON out, not YAML: kubectl reads both; PyYAML is not in the macOS python3 (gotcha #110)
d=json.loads(json.dumps(json.load(sys.stdin)).replace("${DS_PROMETHEUS}", os.environ["DSUID"]))
d.pop("__inputs",None); d.pop("__requires",None); d["id"]=None; d["uid"]=os.environ["UID_"]; d["title"]=d.get("title","")+os.environ["SUFFIX"]
cm={"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":os.environ["NAME"],"namespace":os.environ["NS"],"labels":{"grafana_dashboard":"1"}},
    "data":{os.environ["UID_"]+".json": json.dumps(d,separators=(",",":"))}}
if os.environ["FOLDER"]: cm["metadata"]["annotations"]={"grafana_folder":os.environ["FOLDER"]}
print(json.dumps(cm, indent=1))'
