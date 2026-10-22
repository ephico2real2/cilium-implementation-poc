#!/usr/bin/env bash
# Checks the running lab end to end, from this Mac, through Envoy's published port.
#
# Usage: scripts/verify.sh [phase ...] [-h|--help]
#   phase1   edge_sni, web, tcp-svc: TLS pass-through, SNI routing, resets, isolation
#   phase2   orders-api and Postgres: Swagger, idempotent orders, admin token, CORS, mesh_pg
#   phase3   IBM MQ and the worker: native client in three SNI modes, the order flow,
#            metrics through mesh_http, Envoy's TLS to the MQ REST API
#   phase6   OpenTelemetry: spans enter through Envoy, collector isolation and metrics; the
#            four stores ready and isolated, Grafana's datasources, and one run of traces,
#            metrics and logs found in the stores
#   phase5   failures: 50% chaos, Postgres restart, MQ stop and start, tcp-svc stop and start.
#            It stops and restarts containers on purpose, so it is never part of the default.
#   (no argument)  phase1 phase2 phase3. Phase 4 (metrics) is checked by tests/dashboard_*.py.
# Each check prints PASS or FAIL with what it saw; the exit status is the number of failures.

# Phase functions are called by name from the command line, so shellcheck cannot see the calls.
# shellcheck disable=SC2329
set -uo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEMO_DIR
readonly CA="${DEMO_DIR}/certs/ca/ca.crt"
readonly PORT="${FABRIC_TLS_PORT:-8443}"
readonly DOMAIN="fabric.localtest.me"
OPENSSL="${OPENSSL:-openssl}"
FAILURES=0

pass() { printf 'PASS  %-46s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-46s %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }
check() {  # check <name> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then pass "$1" "$(echo "$3" | grep -F -m1 -- "$2" | cut -c1-70)"; else fail "$1" "expected '$2', got '$(echo "$3" | head -3 | tr '\n' ' ' | cut -c1-90)'"; fi
}
# For values where a substring would lie (2 inside 12, "processed 1" inside "processed 10").
check_exact() {  # check_exact <name> <expected> <actual>
  if [ "$3" = "$2" ]; then pass "$1" "$3"; else fail "$1" "expected exactly '$2', got '${3:-<empty>}'"; fi
}

# Sends lines to a TLS service through Envoy and prints its replies.
tls_lines() {  # tls_lines <sni> <line>...
  local sni="$1"; shift
  { for line in "$@"; do printf '%s\n' "${line}"; sleep 0.2; done; sleep 0.5; } \
    | "${OPENSSL}" s_client -quiet -connect "127.0.0.1:${PORT}" -servername "${sni}" \
        -verify_hostname "${sni}" -verify_return_error -CAfile "${CA}" 2>/dev/null
}

envoy_stat() {  # envoy_stat <exact stat name>
  podman exec fabric-envoy-1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/9901; printf "GET /stats?filter=^%s$ HTTP/1.1\r\nHost: l\r\nConnection: close\r\n\r\n" "$1" >&3; cat <&3' _ "$1" \
    | sed -n "s/^$1: //p"
}

in_container() {  # in_container <service> <command...>
  podman exec "fabric-$1-1" "${@:2}" 2>&1
}

phase1() {
  echo "== Phase 1: edge_sni, web, tcp-svc"
  local out
  out="$(curl -s --cacert "${CA}" -o /dev/null -w '%{http_code} %{ssl_verify_result}' "https://web.${DOMAIN}:${PORT}/")"
  check "web: Orders page over TLS, CA-verified" "200 0" "${out}"
  out="$(curl -s --cacert "${CA}" "https://web.${DOMAIN}:${PORT}/admin" | grep -o '<title>[^<]*</title>')"
  check "web: Admin portal page" "<title>Fabric Admin</title>" "${out}"
  out="$(curl -s --cacert "${CA}" -D - -o /dev/null "https://web.${DOMAIN}:${PORT}/" | grep -i '^content-security-policy')"
  check "web: Content-Security-Policy header" "connect-src 'self' https://api.${DOMAIN}" "${out}"
  out="$("${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -servername "web.${DOMAIN}" </dev/null 2>/dev/null | "${OPENSSL}" x509 -noout -subject)"
  check "edge_sni: TLS ends at web, not Envoy" "CN=web.${DOMAIN}" "${out}"

  out="$(tls_lines "tcp.${DOMAIN}" PING "ECHO hello fabric" HELP NOPE QUIT)"
  check "tcp-svc: PING" "PONG" "${out}"
  check "tcp-svc: ECHO" "hello fabric" "${out}"
  check "tcp-svc: HELP" "COMMANDS PING TIME ECHO HELP QUIT" "${out}"
  check "tcp-svc: unknown command" "ERR unknown command" "${out}"
  check "tcp-svc: QUIT" "BYE" "${out}"
  out="$(tls_lines "tcp.${DOMAIN}" TIME)"
  check "tcp-svc: TIME is today's UTC date" "$(date -u +%Y-%m-%d)" "${out}"
  out="$(tls_lines "tcp.${DOMAIN}" "ECHO $(head -c 1100 /dev/zero | tr '\0' x)")"
  check "tcp-svc: over-long line refused" "ERR line too long" "${out}"

  local before after
  before="$(envoy_stat 'listener.0.0.0.0_10443.no_filter_chain_match')"
  out="$("${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -servername "unknown.${DOMAIN}" </dev/null 2>&1 | grep -E 'errno|peer certificate' | head -2 | tr '\n' ' ')"
  check "edge_sni: unknown SNI is reset" "no peer certificate available" "${out}"
  out="$("${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -noservername </dev/null 2>&1 | grep -E 'errno|peer certificate' | head -2 | tr '\n' ' ')"
  check "edge_sni: missing SNI is reset" "no peer certificate available" "${out}"
  after="$(envoy_stat 'listener.0.0.0.0_10443.no_filter_chain_match')"
  # Compared as numbers, never as substrings. At least 2, not exactly 2: the counter is the whole
  # listener's, so any other client's unknown SNI in this window counts too.
  if [[ "${before}" =~ ^[0-9]+$ ]] && [[ "${after}" =~ ^[0-9]+$ ]] && [ "${after}" -ge $((before + 2)) ]; then
    pass "envoy: no_filter_chain_match rose by 2" "${before} -> ${after}"
  else
    fail "envoy: no_filter_chain_match rose by 2" "${before:-missing} -> ${after:-missing}"
  fi

  out="$(in_container tcp-svc python -c "import socket; socket.create_connection(('web', 8443), 2)")"
  check "isolation: tcp-svc cannot resolve web" "Name or service not known" "${out}"
  out="$(in_container web nc -z -w 2 tcp-svc 9000; echo "exit=$?")"
  check "isolation: web cannot reach tcp-svc" "bad address" "${out}"
  out="$(in_container tcp-svc python -c "import socket; socket.create_connection(('example.com', 443), 3)")"
  check "isolation: tcp-svc has no route out" "Name or service not known" "${out}"
  out="$(in_container tcp-svc sh -c 'cat /tls/web/tls.key' )"
  check "isolation: tcp-svc cannot read web's key" "Permission denied" "${out}"
}

api() {  # api <method> <path> [curl args...]  -> body, then a last line "HTTP <code>"
  local method="$1" path="$2"; shift 2
  curl -s --cacert "${CA}" -X "${method}" -w '\nHTTP %{http_code}' "$@" "https://api.${DOMAIN}:${PORT}${path}"
}

json_field() {  # json_field <python expression on d>  (reads JSON from stdin, ignores the HTTP line)
  python3 -c "import json,sys; d=json.loads(sys.stdin.read().rsplit('\nHTTP',1)[0]); print($1)"
}

phase2() {
  echo "== Phase 2: orders-api, postgres, mesh_pg"
  local out key id token
  out="$(api GET /docs)"
  check "api: Swagger UI at /docs" "swagger-ui" "${out}"
  out="$(api GET /openapi.json | json_field 'd["info"]["title"], "/orders" in d["paths"], "/admin/chaos" in d["paths"]')"
  check_exact "api: OpenAPI lists /orders and /admin/chaos" "orders-api True True" "${out}"

  key="$(uuidgen)"
  out="$(api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: ${key}" -d '{"item":"espresso","quantity":2}')"
  check "orders: POST creates (201)" "HTTP 201" "${out}"
  id="$(echo "${out}" | json_field 'd["id"]')"
  out="$(api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: ${key}" -D - -d '{"item":"espresso","quantity":2}')"
  check "orders: same key replays (200)" "HTTP 200" "${out}"
  check "orders: replay header" "idempotent-replayed: true" "$(echo "${out}" | tr '[:upper:]' '[:lower:]')"
  check "orders: replay returns the same order" "\"id\":${id}," "${out}"
  out="$(api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: ${key}" -d '{"item":"cortado","quantity":2}')"
  check "orders: same key, other body refused (422)" "HTTP 422" "${out}"
  out="$(api POST /orders -H 'Content-Type: application/json' -d '{"item":"espresso","quantity":1}')"
  check "orders: missing Idempotency-Key refused" "HTTP 422" "${out}"
  out="$(api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" -d '{"item":"espresso","quantity":99}')"
  check "orders: quantity over 20 refused" "HTTP 422" "${out}"
  # Status is left out: once the worker runs (phase 3), the order may already be processed.
  out="$(api GET "/orders/${id}" | json_field 'd["item"], d["quantity"]')"
  check "orders: GET by id" "espresso 2" "${out}"
  out="$(api PUT "/orders/${id}/status" -H 'Content-Type: application/json' -d '{"status":"processed"}')"
  check "orders: status update not exposed publicly" "HTTP 404" "${out}"

  out="$(api GET /tcp/ping)"
  check "tcp: API pings tcp-svc through edge_sni" '"reply":"PONG"' "${out}"

  token="$(cat "${DEMO_DIR}/secrets/admin-token")"
  out="$(api GET /admin/overview)"
  check "admin: no token refused" "HTTP 401" "${out}"
  out="$(api GET /admin/overview -H 'Authorization: Bearer wrong')"
  check "admin: wrong token refused" "HTTP 401" "${out}"
  out="$(api GET /admin/overview -H "Authorization: Bearer ${token}" | json_field '" ".join(h["name"] + "=" + str(h["ok"]) for h in d["health"])')"
  check "admin: envoy, postgres, web, tcp-svc up" "envoy=True postgres=True web=True tcp-svc=True" "${out}"
  out="$(api PUT /admin/chaos -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' -d '{"fail_rate":2,"delay_ms":0}')"
  check "admin: chaos rejects a rate over 1" "HTTP 422" "${out}"

  out="$(curl -s --cacert "${CA}" -X OPTIONS -D - -o /dev/null "https://api.${DOMAIN}:${PORT}/orders" -H "Origin: https://web.${DOMAIN}:${PORT}" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: idempotency-key,content-type' | tr '[:upper:]' '[:lower:]')"
  check "cors: web origin allowed" "access-control-allow-origin: https://web.${DOMAIN}:${PORT}" "${out}"
  out="$(curl -s --cacert "${CA}" -X OPTIONS -D - -o /dev/null "https://api.${DOMAIN}:${PORT}/orders" -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST' | tr '[:upper:]' '[:lower:]')"
  if [[ "${out}" != *"access-control-allow-origin"* ]]; then pass "cors: other origin not allowed" "no allow-origin header"; else fail "cors: other origin not allowed" "${out}"; fi

  out="$(in_container orders-api python -c "import socket; socket.create_connection(('postgres', 5432), 2)")"
  check "isolation: orders-api cannot resolve postgres" "Name or service not known" "${out}"
  out="$(envoy_stat 'tcp.postgres.downstream_cx_total')"
  if [ "${out:-0}" -gt 0 ]; then pass "envoy: Postgres traffic went through mesh_pg" "tcp.postgres.downstream_cx_total=${out}"; else fail "envoy: Postgres traffic went through mesh_pg" "counter ${out:-missing}"; fi
}

mq_client() {  # mq_client <mode>  -> the client's output (runs the tools-profile container)
  (cd "${DEMO_DIR}" && podman compose run --rm mq-client "$1" 2>&1 | grep -v -E '>>>>|Executing external|^\s*$')
}

mesh_get() {  # mesh_get <url>  -> body, fetched from inside orders-api through Envoy's mesh_http
  in_container orders-api python -c "import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=10).read().decode())" "$1"
}

# Only samples from the last three scrapes (10 s apart): a plain query would return a restarted
# collector's old last value for 5 minutes. A restarted collector has no series until its first
# span, so a fresh `up` sample stands for zero then; with no fresh scrape at all the answer is
# empty and this fails, rather than invent a zero the next cumulative sample would look past.
prometheus_value() {  # prometheus_value -> sum of accepted spans; exits 1 without a fresh scrape
  curl -fsS --get --data-urlencode 'query=sum(last_over_time(otelcol_receiver_accepted_spans_total[30s])) or on() (0 * sum(last_over_time(up{job="otel-collector"}[30s])))' \
    "http://prometheus.fabric.localtest.me:8080/api/v1/query" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["data"]["result"]; print(r[0]["value"][1]) if r else sys.exit(1)'
}

phase3() {
  echo "== Phase 3: IBM MQ, worker, mesh_http"
  local out before after key id status i token
  out="$(mq_client hostname)"
  check "mq: put and get with OutboundSNI=HOSTNAME" "RESULT ok: both messages" "${out}"
  before="$(envoy_stat 'listener.0.0.0.0_10443.no_filter_chain_match')"
  out="$(mq_client channel)"
  check "mq: channel-name SNI refused" "RESULT ok: refused" "${out}"
  after="$(envoy_stat 'listener.0.0.0.0_10443.no_filter_chain_match')"
  if [ "${after:-0}" -gt "${before:-0}" ]; then pass "envoy: channel SNI had no chain" "no_filter_chain_match ${before} -> ${after}"; else fail "envoy: channel SNI had no chain" "${before} -> ${after}"; fi
  out="$(mq_client nocert)"
  check "mq: no client certificate refused" "RESULT ok: refused" "${out}"

  out="$("${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -servername "mqconsole.${DOMAIN}" -verify_hostname "mqconsole.${DOMAIN}" -CAfile "${CA}" </dev/null 2>/dev/null | grep 'Verify return code')"
  check "mq console: TLS ends at MQ, name verified" "Verify return code: 0 (ok)" "${out}"
  out="$(curl -s --cacert "${CA}" -o /dev/null -w '%{http_code} %{redirect_url}' "https://mqconsole.${DOMAIN}:${PORT}/ibmmq/console/")"
  check "mq console: redirects to its login page" "302 https://mqconsole.${DOMAIN}:${PORT}/ibmmq/console/login.html" "${out}"

  # The MQ REST API comes up after the queue manager: wait until the API sees it, so the
  # order below tests the flow rather than the start-up order.
  token="$(cat "${DEMO_DIR}/secrets/admin-token")"
  for i in $(seq 1 30); do
    out="$(api GET /admin/overview -H "Authorization: Bearer ${token}" | json_field '[h["ok"] for h in d["health"] if h["name"] == "mq"][0]')"
    [ "${out}" = "True" ] && break
    sleep 3
  done
  check "mq: REST API reachable through mesh_http" "True" "${out} (after $((i * 3 - 3))s)"

  key="$(uuidgen)"
  id="$(api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: ${key}" -d '{"item":"flat white","quantity":1}' | json_field 'd["id"]')"
  status=""
  for i in $(seq 1 30); do
    status="$(api GET "/orders/${id}" | json_field 'd["status"], d["events_sent"]')"
    [[ "${status}" == processed* ]] && break
    sleep 1
  done
  if [ "${status}" = "processed 1" ]; then
    pass "flow: order ${id} created -> processed" "${status} (after ${i}s)"
  else
    fail "flow: order ${id} created -> processed" "expected exactly 'processed 1', got '${status:-<empty>}' (after ${i}s)"
  fi

  out="$(api GET /admin/overview -H "Authorization: Bearer ${token}" | json_field '" ".join(h["name"] + "=" + str(h["ok"]) for h in d["health"])')"
  check "admin: every component up" "envoy=True postgres=True web=True tcp-svc=True mq=True worker=True" "${out}"

  for target in envoy orders-api tcp-svc worker mq; do
    out="$(mesh_get "http://metrics.mesh:18080/metrics/${target}" | grep -c '^[a-z]' || true)"
    if [ "${out:-0}" -gt 10 ]; then pass "metrics: /metrics/${target} through mesh_http" "${out} samples"; else fail "metrics: /metrics/${target} through mesh_http" "${out:-0} samples"; fi
  done
  # Present and above zero: the flow above has just been processed.
  out="$(mesh_get "http://metrics.mesh:18080/metrics/worker" | sed -n 's/^worker_messages_total{result="processed"} //p')"
  if awk -v value="${out}" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'; then
    pass "worker: processed counter" "worker_messages_total{result=\"processed\"} ${out}"
  else
    fail "worker: processed counter" "expected a positive counter, got '${out:-missing}'"
  fi
  out="$(envoy_stat 'cluster.mq_web.ssl.handshake')"
  if [ "${out:-0}" -gt 0 ]; then pass "envoy: verified TLS to the MQ REST API" "cluster.mq_web.ssl.handshake=${out}"; else fail "envoy: verified TLS to the MQ REST API" "${out:-missing}"; fi
  # Exactly 0, and present: as a substring, 10 would have passed, and so would a missing stat.
  out="$(envoy_stat 'cluster.mq_web.ssl.fail_verify_san')"
  if [ "${out}" = "0" ]; then pass "envoy: MQ certificate name matched" "fail_verify_san=0"; else fail "envoy: MQ certificate name matched" "fail_verify_san=${out:-missing}"; fi

  out="$(in_container worker python -c "import socket; socket.create_connection(('mq', 9443), 2)")"
  check "isolation: worker cannot resolve mq" "Name or service not known" "${out}"
  out="$(in_container worker python -c "import socket; socket.create_connection(('orders-api', 8080), 2)")"
  check "isolation: worker cannot resolve orders-api" "Name or service not known" "${out}"
}

generate() {  # generate <traces|metrics|logs> [telemetrygen args...]  -> its output; sends to otlp.mesh
  (cd "${DEMO_DIR}" && podman compose run --rm telemetrygen "$1" --otlp-http \
    --otlp-endpoint otlp.mesh:18080 --otlp-insecure "${@:2}" 2>&1)
}

store_get() {  # store_get [curl args...] <url>  -> body, fetched from inside Grafana through Envoy's mesh_http
  in_container grafana curl -fsS --max-time 10 "$@"
}

isolation() {  # isolation <container> <network>  -> "<its networks>|<the network's other members>|<internal>"
  local networks peers internal
  networks="$(podman inspect "$1" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; print(" ".join(sorted(d["NetworkSettings"]["Networks"])))' 2>/dev/null)"
  peers="$(podman network inspect "$2" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; cs=d.get("containers", d.get("Containers", {})); names=sorted(c.get("name", c.get("Name", "")) for c in cs.values()); print(" ".join(n for n in names if n != sys.argv[1]))' "$1" 2>/dev/null)"
  # Without internal: true the network would have a route out, and outside names would resolve.
  internal="$(podman network inspect "$2" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("internal", False))' 2>/dev/null)"
  echo "${networks}|${peers}|${internal}"
}

tempo_ids() {  # tempo_ids <service>  -> the trace ids Tempo holds for it, sorted, 32 hex digits each
  local now; now="$(date +%s)"
  store_get -G --data-urlencode "q={resource.service.name=\"$1\"}" --data-urlencode "start=$((now - 600))" \
    --data-urlencode "end=$((now + 60))" --data-urlencode limit=50 http://tempo.mesh:18080/api/search \
    | python3 -c 'import json,sys; print(" ".join(sorted(t["traceID"].rjust(32, "0") for t in json.load(sys.stdin).get("traces", []))))' 2>/dev/null
}

vtraces_ids() {  # vtraces_ids <service>  -> the same from VictoriaTraces' Jaeger API
  store_get -G --data-urlencode "service=$1" --data-urlencode limit=50 \
    http://victoriatraces.mesh:18080/select/jaeger/api/traces \
    | python3 -c 'import json,sys; print(" ".join(sorted(t["traceID"].rjust(32, "0") for t in json.load(sys.stdin).get("data") or [])))' 2>/dev/null
}

phase6() {
  echo "== Phase 6: OpenTelemetry collector and the telemetry stores"
  # Each telemetrygen trace is a parent and one child span (--child-spans defaults to 1), and
  # telemetrygen exits 0 even when every trace export failed, so its log is read for export
  # errors. Its metrics and logs commands exit non-zero instead.
  local traces=5 out before after before_status generator_status after_status export_errors \
    isolated collector_networks peers internal entry store network url want i uid run tempo vtraces \
    tempo_list first log_trace_id value
  local sent=$((traces * 2))
  # <service> <its network> <readiness URL through Envoy> <the answer when ready>
  local stores=(
    "tempo net-tempo http://tempo.mesh:18080/ready ready"
    "victoria-traces net-vtraces http://victoriatraces.mesh:18080/health OK"
    "victoria-metrics net-vmetrics http://victoriametrics.mesh:18080/health OK"
    "victoria-logs net-vlogs http://victorialogs.mesh:18080/health OK"
  )

  before="$(prometheus_value 2>/dev/null)"; before_status=$?
  out="$(generate traces --traces "${traces}")"; generator_status=$?
  export_errors="$(grep -c 'traces export:' <<<"${out}")"
  # Prometheus scrapes every 10 s: 15 s later its last sample postdates the last export.
  sleep 15
  after="$(prometheus_value 2>/dev/null)"; after_status=$?
  if [ "${before_status}" -eq 0 ] && [ "${generator_status}" -eq 0 ] && \
     [ "${export_errors}" -eq 0 ] && [ "${after_status}" -eq 0 ] && \
     awk -v before="${before}" -v after="${after}" -v sent="${sent}" 'BEGIN { exit ! (after - before >= sent) }'; then
    pass "otel: a span reaches the collector through Envoy" "accepted spans ${before} -> ${after} (${sent} sent)"
  else
    fail "otel: a span reaches the collector through Envoy" \
      "before=${before:-query failed}, after=${after:-query failed}, sent=${sent}, generator=${generator_status}, export errors=${export_errors}: $(grep -m1 'traces export:' <<<"${out}" | cut -c1-70)"
  fi

  isolated="$(isolation fabric-otel-collector-1 fabric_net-otel)"
  IFS='|' read -r collector_networks peers internal <<<"${isolated}"
  if [ "${isolated}" = "fabric_net-otel|fabric-envoy-1|True" ]; then
    pass "isolation: the collector shares a network only with Envoy" \
      "network=${collector_networks} (internal), peer=${peers}"
  else
    fail "isolation: the collector shares a network only with Envoy" \
      "networks=${collector_networks:-missing}, peers=${peers:-missing}, internal=${internal:-missing}"
  fi

  out="$(mesh_get "http://metrics.mesh:18080/metrics/otel-collector" | grep -c '^[a-z]' || true)"
  if [ "${out:-0}" -gt 10 ]; then
    pass "metrics: the collector's own metrics through mesh_http" "${out} samples"
  else
    fail "metrics: the collector's own metrics through mesh_http" "${out:-0} samples"
  fi

  # Each store: ready when read through Envoy (three images have no shell for a health check),
  # and on an internal network whose only other member is Envoy.
  for entry in "${stores[@]}"; do
    read -r store network url want <<<"${entry}"
    for i in $(seq 1 30); do
      out="$(store_get "${url}")"
      [ "${out}" = "${want}" ] && break
      sleep 2
    done
    isolated="$(isolation "fabric-${store}-1" "fabric_${network}")"
    if [ "${out}" = "${want}" ] && [ "${isolated}" = "fabric_${network}|fabric-envoy-1|True" ]; then
      pass "store: ${store} ready, reached only through Envoy" "${want} after $((i * 2 - 2))s; ${network} (internal) shared with Envoy alone"
    else
      fail "store: ${store} ready, reached only through Envoy" "ready=$(head -1 <<<"${out}" | cut -c1-30); networks|peers|internal=${isolated}"
    fi
    out="$(mesh_get "http://metrics.mesh:18080/metrics/${store}" | grep -c '^[a-z]' || true)"
    if [ "${out:-0}" -gt 10 ]; then pass "metrics: /metrics/${store} through mesh_http" "${out} samples"; else fail "metrics: /metrics/${store} through mesh_http" "${out:-0} samples"; fi
  done

  # Grafana's own test of each datasource, the one its "Save & test" button runs.
  # Bounded, and the status must be exactly OK; no -f, because an unhealthy datasource's reason
  # comes back in the body of an HTTP error and is what the FAIL line should show.
  for uid in prometheus victoriametrics victorialogs tempo victoriatraces; do
    out="$(curl -sS --max-time 10 -u "admin:$(cat "${DEMO_DIR}/secrets/grafana-admin-password")" \
      "http://grafana.fabric.localtest.me:8080/api/datasources/uid/${uid}/health" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("status=" + str(d.get("status")), d.get("message"))' 2>&1)"
    if [ "${out%% *}" = "status=OK" ]; then
      pass "grafana: datasource ${uid} answers OK" "${out}"
    else
      fail "grafana: datasource ${uid} answers OK" "got '$(echo "${out}" | head -3 | tr '\n' ' ' | cut -c1-90)'"
    fi
  done

  # One run, named so its telemetry can be told apart: traces, then metrics and logs, through
  # the collector to every store. VictoriaTraces and VictoriaMetrics show new data only after
  # their 30 s -search.latencyOffset, so each lookup waits up to 90 s.
  run="phase6-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
  out="$(generate traces --traces "${traces}" --service "${run}")"; generator_status=$?
  export_errors="$(grep -c 'traces export:' <<<"${out}")"
  for i in $(seq 1 30); do
    tempo="$(tempo_ids "${run}")"; vtraces="$(vtraces_ids "${run}")"
    read -r -a tempo_list <<<"${tempo}"
    [ "${#tempo_list[@]}" -ge "${traces}" ] && [ "${tempo}" = "${vtraces}" ] && break
    sleep 3
  done
  first="${tempo_list[0]:-}"
  if [ "${generator_status}" -eq 0 ] && [ "${export_errors}" -eq 0 ] && \
     [ "${#tempo_list[@]}" -eq "${traces}" ] && [ "${tempo}" = "${vtraces}" ]; then
    pass "stores: the same ${traces} trace ids in Tempo and VictoriaTraces" "${run} after $((i * 3 - 3))s, e.g. ${first}"
  else
    fail "stores: the same ${traces} trace ids in Tempo and VictoriaTraces" \
      "${run}: generator=${generator_status}, export errors=${export_errors}, Tempo [${tempo}], VictoriaTraces [${vtraces}]"
  fi

  out="$(generate metrics --metrics 5 --service "${run}")"; generator_status=$?
  for i in $(seq 1 30); do
    value="$(store_get -G --data-urlencode "query=count_over_time({\"service.name\"=\"${run}\"}[10m])" \
      http://victoriametrics.mesh:18080/api/v1/query \
      | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)"
    [ "${value}" = "5" ] && break
    sleep 3
  done
  if [ "${generator_status}" -eq 0 ] && [ "${value}" = "5" ]; then
    pass "stores: the run's metrics in VictoriaMetrics" "5 of 5 samples after $((i * 3 - 3))s"
  else
    fail "stores: the run's metrics in VictoriaMetrics" "generator=${generator_status}, samples=${value:-query failed}: $(grep -m1 -i 'error' <<<"${out}" | cut -c1-70)"
  fi

  # The log lines carry one of the run's trace ids, as a service's would inside a span (a fresh
  # id if no trace arrived, so this check stands on its own).
  log_trace_id="${first:-$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')}"
  out="$(generate logs --logs 5 --service "${run}" --trace-id "${log_trace_id}")"; generator_status=$?
  for i in $(seq 1 30); do
    value="$(store_get -G --data-urlencode "query=service.name:=\"${run}\"" \
      http://victorialogs.mesh:18080/select/logsql/query \
      | python3 -c 'import json,sys; ls=[json.loads(l) for l in sys.stdin if l.strip()]; print(len(ls), " ".join(sorted({l.get("trace_id", "none") for l in ls})))' 2>/dev/null)"
    [ "${value}" = "5 ${log_trace_id}" ] && break
    sleep 3
  done
  if [ "${generator_status}" -eq 0 ] && [ "${value}" = "5 ${log_trace_id}" ]; then
    pass "stores: the run's logs in VictoriaLogs" "5 lines with trace_id ${log_trace_id} after $((i * 3 - 3))s"
  else
    fail "stores: the run's logs in VictoriaLogs" "generator=${generator_status}, lines and trace ids=${value:-query failed}, want 5 ${log_trace_id}"
  fi
}

new_order() {  # new_order <item>  -> the new order's id
  api POST /orders -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" \
    -d "{\"item\":\"$1\",\"quantity\":1}" | json_field 'd["id"]'
}

wait_processed() {  # wait_processed <seconds> <id>...  -> "processed=N of M after Xs"
  local limit="$1"; shift
  local waited=0 done_count id
  while :; do
    done_count=0
    for id in "$@"; do
      [ "$(api GET "/orders/${id}" | json_field 'd["status"]')" = "processed" ] && done_count=$((done_count + 1))
    done
    [ "${done_count}" -eq "$#" ] || [ "${waited}" -ge "${limit}" ] && break
    sleep 3; waited=$((waited + 3))
  done
  echo "processed=${done_count} of $# after ${waited}s"
}

set_chaos() {  # set_chaos <fail_rate 0..1>
  api PUT /admin/chaos -H "Authorization: Bearer $(cat "${DEMO_DIR}/secrets/admin-token")" \
    -H 'Content-Type: application/json' -d "{\"fail_rate\":$1,\"delay_ms\":0}" >/dev/null
}

wait_healthy() {  # wait_healthy <service> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    [ "$(podman inspect "fabric-$1-1" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ] && return 0
    sleep 1
  done
  return 1
}

phase5() {
  echo "== Phase 5: failures and recovery"
  local ids=() i out before after id

  # 1. Half the status updates fail: Envoy's retries and the worker's put-back must still
  #    get every order processed.
  before="$(envoy_stat 'cluster.orders_api_internal.upstream_rq_retry')"
  set_chaos 0.5
  for i in $(seq 1 10); do ids+=("$(new_order cortado)"); done
  out="$(wait_processed 90 "${ids[@]}")"
  set_chaos 0
  check "chaos 50%: every order still processed" "processed=10 of 10" "${out}"
  after="$(envoy_stat 'cluster.orders_api_internal.upstream_rq_retry')"
  if [ "${after:-0}" -gt "${before:-0}" ]; then pass "chaos 50%: Envoy retried the failed PUTs" "upstream_rq_retry ${before} -> ${after}"; else fail "chaos 50%: Envoy retried the failed PUTs" "${before} -> ${after}"; fi

  # 2. Postgres restarts: the API must come back without anyone restarting it.
  podman restart fabric-postgres-1 >/dev/null
  wait_healthy postgres 60 || true
  out=""
  for i in $(seq 1 20); do
    id="$(new_order espresso 2>/dev/null)"
    [[ "${id}" =~ ^[0-9]+$ ]] && { out="order ${id} created ${i} attempt(s) after the restart"; break; }
    sleep 2
  done
  check "postgres restart: API recovers on its own" "created" "${out:-no order in 20 attempts}"

  # 3. MQ restarts: an order created while MQ is down gets its event from the sweeper.
  podman stop fabric-mq-1 >/dev/null
  id="$(new_order 'matcha latte')"
  out="$(api GET "/orders/${id}" | json_field 'd["status"], d["events_sent"]')"
  check "mq down: order still accepted, no event yet" "created 0" "${out}"
  podman start fabric-mq-1 >/dev/null
  wait_healthy mq 180 || true
  out="$(wait_processed 150 "${id}")"
  check "mq back: the sweeper's resend gets it processed" "processed=1 of 1" "${out}"

  # 4. tcp-svc stops: the API answers 502 rather than hanging, then recovers.
  podman stop fabric-tcp-svc-1 >/dev/null
  out="$(api GET /tcp/ping)"
  check "tcp-svc down: ping fails cleanly" "HTTP 502" "${out}"
  podman start fabric-tcp-svc-1 >/dev/null
  wait_healthy tcp-svc 30 || true
  out="$(api GET /tcp/ping)"
  check "tcp-svc back: ping works again" '"reply":"PONG"' "${out}"
}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ -s "${CA}" ] || { echo "verify: ${CA} missing; run scripts/gen-certs.sh" >&2; exit 1; }
phases=("$@")
[ ${#phases[@]} -gt 0 ] || phases=(phase1 phase2 phase3)
# An unknown name would otherwise run nothing, count no failure and exit 0.
for p in "${phases[@]}"; do
  case "${p}" in
    phase1|phase2|phase3|phase5|phase6) ;;
    *) echo "verify: unknown phase: ${p} (see --help)" >&2; exit 1 ;;
  esac
done
for p in "${phases[@]}"; do "${p}"; done
echo
echo "failures: ${FAILURES}"
exit "${FAILURES}"
