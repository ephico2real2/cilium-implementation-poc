#!/usr/bin/env bash
# Usage: test_store_routes.sh   (against the running lab)
# Envoy routes only each store's write path, the read API Grafana uses and the readiness probe;
# an admin, delete or other write path must get Envoy's 404. Asked from inside Grafana, which
# holds every store alias.
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
expect_ops() {  # expect_ops <code> <method> <path>; ask ops_http from Envoy's Grafana network
  local got
  got="$(podman exec fabric-grafana-1 curl -g -s -o /dev/null -w '%{http_code}' -X "$2" \
    -H 'Host: victoriametrics.fabric.localtest.me' "http://victoriametrics.mesh:10080$3")"
  if [ "${got}" = "$1" ]; then echo "ok        $2 victoriametrics.fabric.localtest.me$3 -> ${got}"; else echo "MISMATCH  $2 victoriametrics.fabric.localtest.me$3 -> ${got} (want $1)"; bad=$((bad + 1)); fi
}
refuse_ops() {  # refuse_ops <method> <path>; require ops_http's own fallback body
  local got code body
  got="$(podman exec fabric-grafana-1 curl -g -s -w $'\n%{http_code}' -X "$1" \
    -H 'Host: victoriametrics.fabric.localtest.me' "http://victoriametrics.mesh:10080$2")"
  code="${got##*$'\n'}"
  body="${got%$'\n'*}"
  if [ "${code}" = 404 ] && [ "${body}" = "not routed on victoriametrics.fabric.localtest.me" ]; then
    echo "ok        $1 victoriametrics.fabric.localtest.me$2 -> Envoy 404"
  else
    echo "MISMATCH  $1 victoriametrics.fabric.localtest.me$2 -> ${code}, body '${body}' (want Envoy 404)"; bad=$((bad + 1))
  fi
}
expect 404 POST victoriametrics.mesh '/api/v1/admin/tsdb/delete_series?match[]=gen'
expect 404 POST victoriametrics.mesh /api/v1/import
expect 404 POST victoriametrics.mesh /api/v1/write
expect 404 GET victoriametrics.mesh /snapshot/create
expect 404 GET victorialogs.mesh /internal/force_merge
expect 404 GET victoriatraces.mesh '/select/logsql/query?query=*'
expect 404 GET tempo.mesh /status/config
expect 404 GET tempo.mesh /flush
expect 404 POST tempo.mesh /api/echo
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
# The host-facing VictoriaMetrics endpoint exposes only the anchored read API, never a write,
# destructive admin call, reload or the collector's OTLP ingestion path.
expect_ops 200 GET '/api/v1/query?query=1'
expect_ops 200 POST '/api/v1/query?query=1'
refuse_ops POST /api/v1/import
refuse_ops POST '/api/v1/admin/tsdb/delete_series?match[]=gen'
refuse_ops POST /api/v1/write
refuse_ops POST /-/reload
refuse_ops POST /opentelemetry/v1/metrics
echo "mismatches: ${bad}"; exit "${bad}"
