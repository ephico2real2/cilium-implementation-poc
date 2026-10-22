#!/usr/bin/env bash
# Usage: test_store_routes.sh   (against the running lab)
# On the mesh, Envoy routes only each store's write path, the read API Grafana uses and the
# readiness probe; an admin, delete or other write path must get Envoy's 404. On the host,
# VictoriaMetrics is the whole app. Asked from inside Grafana, which holds every store alias.
set -u
bad=0
expect() {  # expect <code> <method> <alias> <path>
  local got
  got="$(podman exec fabric-grafana-1 curl -g -s -o /dev/null -w '%{http_code}' -X "$2" "http://$3:18080$4")"
  if [ "${got}" = "$1" ]; then echo "ok        $2 $3$4 -> ${got}"; else echo "MISMATCH  $2 $3$4 -> ${got} (want $1)"; bad=$((bad + 1)); fi
}
refuse() {  # refuse <method> <alias> <path>; require Envoy's own fallback, not an upstream 404
  local got code body
  got="$(podman exec fabric-grafana-1 curl -g -s -w $'\n%{http_code}' -X "$1" "http://$2:18080$3")"
  code="${got##*$'\n'}"
  body="${got%$'\n'*}"
  if [ "${code}" = 404 ] && [[ "${body}" == "not routed on "* ]]; then
    echo "ok        $1 $2$3 -> Envoy 404"
  else
    echo "MISMATCH  $1 $2$3 -> ${code}, body '${body}' (want Envoy 404)"; bad=$((bad + 1))
  fi
}
reach() {  # reach <method> <alias> <path>; require any upstream answer, not Envoy's fallback
  local got code body
  got="$(podman exec fabric-grafana-1 curl -g -s -w $'\n%{http_code}' -X "$1" "http://$2:18080$3")"
  code="${got##*$'\n'}"
  body="${got%$'\n'*}"
  if [ "${code}" != 404 ] || [[ "${body}" != "not routed on "* ]]; then
    echo "ok        $1 $2$3 -> upstream ${code}"
  else
    echo "MISMATCH  $1 $2$3 -> Envoy 404 (want an upstream answer)"; bad=$((bad + 1))
  fi
}
expect_ops() {  # expect_ops <code> <method> <path>; ask ops_http from Envoy's Grafana network
  local got
  got="$(podman exec fabric-grafana-1 curl -g -s -o /dev/null -w '%{http_code}' -X "$2" \
    -H 'Host: victoriametrics.fabric.localtest.me' "http://victoriametrics.mesh:10080$3")"
  if [ "${got}" = "$1" ]; then echo "ok        $2 victoriametrics.fabric.localtest.me$3 -> ${got}"; else echo "MISMATCH  $2 victoriametrics.fabric.localtest.me$3 -> ${got} (want $1)"; bad=$((bad + 1)); fi
}
expect_ops_body() {  # expect_ops_body <code> <path> <text>; a GET whose body must hold <text>
  local got code body
  got="$(podman exec fabric-grafana-1 curl -g -s -w $'\n%{http_code}' \
    -H 'Host: victoriametrics.fabric.localtest.me' "http://victoriametrics.mesh:10080$2")"
  code="${got##*$'\n'}"
  body="${got%$'\n'*}"
  if [ "${code}" = "$1" ] && [[ "${body}" == *"$3"* ]]; then
    echo "ok        GET victoriametrics.fabric.localtest.me$2 -> ${code}, holds '$3'"
  else
    echo "MISMATCH  GET victoriametrics.fabric.localtest.me$2 -> ${code} (want $1 holding '$3')"; bad=$((bad + 1))
  fi
}
refuse POST victoriametrics.mesh '/api/v1/admin/tsdb/delete_series?match[]=gen'
refuse POST victoriametrics.mesh /api/v1/import
# Any mesh caller could already write OTLP metrics; remote write is the same, from the mesh.
reach POST victoriametrics.mesh /api/v1/write
refuse GET victoriametrics.mesh /snapshot/create
refuse GET victorialogs.mesh /internal/force_merge
refuse GET victoriatraces.mesh '/select/logsql/query?query=*'
refuse GET tempo.mesh /status/config
refuse GET tempo.mesh /flush
refuse POST tempo.mesh /api/echo
refuse GET tempo.mesh /v1/traces
refuse POST tempo.mesh /ready
refuse GET victoriatraces.mesh /insert/opentelemetry/v1/traces
refuse POST victoriatraces.mesh /health
refuse GET victoriametrics.mesh /opentelemetry/v1/metrics
refuse POST victoriametrics.mesh /health
refuse GET victorialogs.mesh /insert/opentelemetry/v1/logs
refuse POST victorialogs.mesh /health
expect 200 GET victoriametrics.mesh '/api/v1/query?query=1'
expect 200 POST victoriametrics.mesh '/api/v1/query?query=1'
expect 200 GET victorialogs.mesh '/select/logsql/query?query=*&limit=1'
# Reads Grafana makes on its own: the VictoriaLogs plugin's tenant list, the alerting view's rules.
expect 200 POST victorialogs.mesh /select/tenant_ids
expect 200 GET victoriametrics.mesh /api/v1/rules
expect 200 GET victoriametrics.mesh /api/v1/alerts
expect 200 GET tempo.mesh /api/echo
expect 200 GET victoriatraces.mesh /select/jaeger/api/services
expect 200 GET tempo.mesh /ready
expect 200 GET victoriatraces.mesh /health
expect 200 GET victoriametrics.mesh /health
expect 200 GET victorialogs.mesh /health
# The host-facing VictoriaMetrics endpoint is the whole app, as Prometheus's is (the operator's
# decision): the UI, its status pages and the admin API all reach the store. Asked without
# changing data: a GET on delete_series gets the store's own 405, an empty import adds nothing.
expect_ops 200 GET '/api/v1/query?query=1'
expect_ops 200 POST '/api/v1/query?query=1'
expect_ops_body 200 / 'Single-node VictoriaMetrics'
expect_ops_body 200 /vmui/ '<title>vmui</title>'
# The page's own script bundle, by the name the page gives it (it changes with each release).
vmui_js="$(podman exec fabric-grafana-1 curl -s -H 'Host: victoriametrics.fabric.localtest.me' \
  http://victoriametrics.mesh:10080/vmui/ | grep -oE 'src="\./assets/index-[^"]+\.js"' | head -1)"
vmui_js="${vmui_js#src=\"./}"
vmui_js="${vmui_js%\"}"
if [ -n "${vmui_js}" ]; then
  expect_ops 200 GET "/vmui/${vmui_js}"
else
  echo "MISMATCH  GET victoriametrics.fabric.localtest.me/vmui/ names no assets/index-*.js"; bad=$((bad + 1))
fi
expect_ops 200 GET /api/v1/status/tsdb
expect_ops 200 GET /api/v1/status/top_queries
expect_ops 200 GET /flags
expect_ops 200 GET /metrics
expect_ops 200 GET /snapshot/list
expect_ops 405 GET /api/v1/admin/tsdb/delete_series
expect_ops 204 POST /api/v1/import
echo "mismatches: ${bad}"; exit "${bad}"
