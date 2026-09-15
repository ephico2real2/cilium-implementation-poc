#!/usr/bin/env bash
# up.sh [dashboard.json] [flow files…] — the dashboard loop without a cluster: render the observer's dashboard the way the lab
# does (the import-time inputs resolved: the Loki datasource, the observer's namespace, the cf2cnp URL), start Loki and
# Grafana with docker compose, replay the flow lines, print the URL. Default dashboard: the fork's, as the lab installs it
# (.tmp/hubble-observer-fork); default lines: the last CI artifact's captures/observer-flows.ndjson if present.
#   demos/25-hubble-observer-loki/local-loop/up.sh
#   demos/25-hubble-observer-loki/local-loop/up.sh path/to/cilium-hubble-flows.json captures/observer-flows.ndjson
#   docker compose -f demos/25-hubble-observer-loki/local-loop/compose.yaml down -v      # to stop and forget
set -euo pipefail; cd "$(dirname "$0")/../../.."; L=demos/25-hubble-observer-loki/local-loop
DASH="${1:-.tmp/hubble-observer-fork/helm/hubble-observer/dashboard/cilium-hubble-flows.json}"; shift || true
[ -s "$DASH" ] || { echo "::error::no dashboard at $DASH (demos/25-hubble-observer-loki/chart-from-fork.sh develop, or pass a file)"; exit 1; }
docker info >/dev/null 2>&1 || { echo "::error::Docker is not running — launch Docker Desktop first (2 CPUs / 8 GB is enough for this loop)"; exit 1; }
# the inputs, as dashboard-from-file.sh resolves them for the sidecar; the uid pinned like the lab's
python3 - "$DASH" "$L/grafana/dashboards/cilium-hubble-flows.json" <<'PY'
import json,sys
raw=open(sys.argv[1]).read().replace('${DS_LOKI}','${datasource}').replace('${VAR_HUBBLEOBSERVERNAMESPACE}','hubble-observer').replace('${VAR_HUBBLEOBSERVERCF2CNPURL}','https://cf2cnp.poc.local')
d=json.loads(raw); d.pop("__inputs",None); d.pop("__requires",None); d["id"]=None; d["uid"]="hubble-observer-23862"
json.dump(d, open(sys.argv[2],"w"), indent=2); print("dashboard rendered ->", sys.argv[2], "(", len(d["panels"]), "top-level panels )")
PY
docker compose -f "$L/compose.yaml" up -d --quiet-pull 2>&1 | tail -2
for _i in $(seq 1 30); do curl -sf http://localhost:3100/ready >/dev/null 2>&1 && curl -sf http://localhost:3000/api/health >/dev/null 2>&1 && break; sleep 2; done
echo "loki: $(curl -s http://localhost:3100/ready); grafana: $(curl -s http://localhost:3000/api/health | tr -d '\n ')"
files=("$@"); [ ${#files[@]} -gt 0 ] || { [ -s captures/observer-flows.ndjson ] && files=(captures/observer-flows.ndjson); }
if [ ${#files[@]} -gt 0 ]; then python3 "$L/replay.py" "${files[@]}"; else echo "no flow files given and no captures/observer-flows.ndjson — replay.py <files> when you have them"; fi
echo "open http://localhost:3000/d/hubble-observer-23862 (admin / poc-grafana); edit $DASH, re-run this script to re-render, the provider reloads within 10 s"
