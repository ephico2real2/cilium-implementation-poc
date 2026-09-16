#!/usr/bin/env bash
# dashboard-from-file.sh <json file> <namespace> <configmap-name> <uid> <folder>
#   The demo 16 dashboard-configmap.sh idea for a LOCAL grafana.com export: resolve the import-time inputs the way the
#   chart's GrafanaDashboard template does (DS_LOKI → the dashboard's own ${datasource} variable, VAR_HUBBLEOBSERVERNAMESPACE →
#   the observer's namespace, VAR_HUBBLEOBSERVERCF2CNPURL → the cf2cnp route's URL, 20-cf2cnp-route.yaml), drop __inputs/__requires, pin the uid,
#   and wrap it in a ConfigMap the sidecar provisions (label grafana_dashboard=1, annotation grafana_folder).
set -euo pipefail
FILE="${1:?json}"; NS="${2:?namespace}"; NAME="${3:?configmap}"; UID_="${4:?uid}"; FOLDER="${5:?folder}"; OBS_NS="${OBS_NS:-hubble-observer}"; CF2CNP_URL="${CF2CNP_URL:-https://cf2cnp.poc.local}"
python3 - "$FILE" <<PY
import json,sys   # JSON out, not YAML: kubectl reads both, and PyYAML is on the Ubuntu runner but not in the macOS python3 (gotcha #110)
raw=open(sys.argv[1]).read().replace('\${DS_LOKI}','\${datasource}').replace('\${VAR_HUBBLEOBSERVERNAMESPACE}','$OBS_NS').replace('\${VAR_HUBBLEOBSERVERCF2CNPURL}','$CF2CNP_URL')
d=json.loads(raw); d.pop("__inputs",None); d.pop("__requires",None); d["id"]=None; d["uid"]="$UID_"
cm={"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"$NAME","namespace":"$NS","labels":{"grafana_dashboard":"1"},"annotations":{"grafana_folder":"$FOLDER"}},
    "data":{"$UID_.json": json.dumps(d,separators=(",",":"))}}
print(json.dumps(cm, indent=1))
PY
