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
expect 200 GET tempo.mesh /api/echo
expect 200 GET victoriatraces.mesh /select/jaeger/api/services
expect 200 GET tempo.mesh /ready
expect 200 GET victoriatraces.mesh /health
expect 200 GET victoriametrics.mesh /health
expect 200 GET victorialogs.mesh /health
echo "mismatches: ${bad}"; exit "${bad}"
