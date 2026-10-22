#!/usr/bin/env bash
# Usage: test_verify_false_pass.sh <path to verify.sh>
# Runs verify.sh against a fake podman, curl and openssl (nothing touches the lab, phase5's
# stop and restart included) and checks that each check below gives the right verdict:
# no number may pass by being a substring of another, no missing value may pass, another
# client's traffic on the shared port must not fail a check, and an unknown phase name must not
# exit 0 with "failures: 0".
set -u
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/stub" "${work}/demo/scripts" "${work}/demo/certs/ca" "${work}/demo/secrets"
cp "$1" "${work}/demo/scripts/verify.sh"
echo dummy > "${work}/demo/certs/ca/ca.crt"
echo fabric-admin > "${work}/demo/secrets/admin-token"

cat > "${work}/stub/podman" <<'STUB'
#!/usr/bin/env bash
# Fake podman: answers only the calls phases 1, 3 and 5 make; never starts or stops anything.
next() {  # next <state name> <space-separated values>: the next value, then the last one again
  local f="${SCEN_DIR}/state.$1" n; n="$(cat "${f}" 2>/dev/null || echo 0)"; echo $((n + 1)) > "${f}"
  read -r -a v <<<"$2"; [ "${n}" -lt "${#v[@]}" ] || n=$((${#v[@]} - 1)); echo "${v[$n]}"
}
case "$1 $2" in
  "exec fabric-envoy-1")
    stat="$7"  # exec fabric-envoy-1 bash -c <script> _ <stat>
    case "${stat}" in
      *no_filter_chain_match) v="$(next nfcm "${SCEN_NFCM}")"; [ "${v}" = missing ] || echo "${stat}: ${v}" ;;
      *fail_verify_san) [ "${SCEN_SAN}" = missing ] || echo "${stat}: ${SCEN_SAN}" ;;
      *) echo "${stat}: $(next "${stat}" "1 50")" ;;
    esac ;;
  "exec fabric-orders-api-1")
    for i in $(seq 1 12); do echo "sample_${i} 1"; done
    echo "worker_messages_total{result=\"processed\"} ${SCEN_WORKER:-2.0}"
    echo "socket.gaierror: [Errno -2] Name or service not known" ;;
  "exec "*) echo "Name or service not known; nc: bad address 'x'; Permission denied" ;;
  "compose run") echo "RESULT ok: both messages put and got back; RESULT ok: refused" ;;
  "inspect "*) echo healthy ;;
  "restart "*|"stop "*|"start "*) ;;
  *) echo "fake podman: unexpected: $*" >&2; exit 99 ;;
esac
STUB

cat > "${work}/stub/curl" <<'STUB'
#!/usr/bin/env bash
# Fake curl: the API, web and MQ console answers verify.sh reads, by URL and method.
# Prometheus with a fresh sample answers it; with no fresh sample at all, an empty result.
if [ -n "${SCEN_PROM_VALUE:-}" ]; then printf '{"data":{"result":[{"metric":{},"value":[0,"%s"]}]}}' "${SCEN_PROM_VALUE}"; exit 0; fi
if [ "${SCEN_PROM_EMPTY:-0}" = 1 ]; then printf '{"data":{"result":[]}}'; exit 0; fi
method=GET; fmt=""; headers=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -D) headers=1; shift ;;
    -H|-d|-o|--cacert|-u|--max-time|--data-urlencode) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "${fmt}" in
  '%{http_code} %{ssl_verify_result}') printf '200 0'; exit 0 ;;
  '%{http_code} %{redirect_url}') printf '302 https://mqconsole.fabric.localtest.me:8443/ibmmq/console/login.html'; exit 0 ;;
esac
[ "${headers}" = 0 ] || printf "content-security-policy: default-src 'self'; connect-src 'self' https://api.fabric.localtest.me\r\n\r\n"
code=200; body=""
openapi='{"info":{"title":"orders-api"},"paths":{"/orders":{},"/orders/{order_id}":{},"/admin/chaos":{}}}'
case "${method} ${url}" in
  "GET "*"/openapi.json") body="${SCEN_OPENAPI:-${openapi}}" ;;
  *"/admin/overview")
    body='{"health":[{"name":"envoy","ok":true},{"name":"postgres","ok":true},{"name":"web","ok":true},{"name":"tcp-svc","ok":true},{"name":"mq","ok":true},{"name":"worker","ok":true}]}' ;;
  "POST "*"/orders")
    if [ "${SCEN_ORDERS}" = down ]; then code=000; else code=201; body='{"id":7,"item":"espresso","quantity":2,"status":"created","events_sent":0}'; fi ;;
  "GET "*/orders/[0-9]*) body="{\"id\":7,\"item\":\"espresso\",\"quantity\":2,\"status\":\"processed\",\"events_sent\":${SCEN_EVENTS:-1}}" ;;
  *"/tcp/ping") body='{"reply":"PONG"}' ;;
esac
printf '%s' "${body}"
[[ "${fmt}" != *'HTTP %{http_code}'* ]] || printf '\nHTTP %s' "${code}"
STUB

cat > "${work}/stub/openssl" <<'STUB'
#!/usr/bin/env bash
# Fake openssl: every line phase 1 and phase 3 look for in s_client and x509 output.
printf '%s\n' "subject=O=SNI Fabric Lab, CN=web.fabric.localtest.me" "Verify return code: 0 (ok)" \
  "no peer certificate available" PONG "hello fabric" "COMMANDS PING TIME ECHO HELP QUIT" \
  "ERR unknown command" BYE "ERR line too long" "$(date -u +%Y-%m-%d)"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/stub/sleep"
chmod +x "${work}/stub/"*

mismatches=0
scenario() {  # scenario <name> <phase> <check name> <want PASS|FAIL> [VAR=value ...]
  local name="$1" phase="$2" check="$3" want="$4" out got verdict=ok
  shift 4
  rm -f "${work}"/state.*
  out="$(env PATH="${work}/stub:${PATH}" OPENSSL=openssl SCEN_DIR="${work}" SCEN_NFCM="1 3" SCEN_SAN=0 \
    SCEN_ORDERS=up "$@" bash "${work}/demo/scripts/verify.sh" "${phase}" 2>&1)"
  got="$(grep -E "^(PASS|FAIL)  ${check}" <<<"${out}" | head -1 | cut -c1-4)"
  [ "${got}" = "${want}" ] || { verdict=MISMATCH; mismatches=$((mismatches + 1)); }
  printf '%-9s %-46s %s (want %s): %s\n' "${verdict}" "${name}" "${got:-none}" "${want}" \
    "$(grep -E "^(PASS|FAIL)  ${check}" <<<"${out}" | head -1 | cut -c53-)"
}
scenario "filter-chain misses 1 -> 3"            phase1 "envoy: no_filter_chain_match" PASS
scenario "1 -> 13 (other clients' unknown SNI)"  phase1 "envoy: no_filter_chain_match" PASS SCEN_NFCM="1 13"
scenario "filter-chain misses 1 -> 2"            phase1 "envoy: no_filter_chain_match" FAIL SCEN_NFCM="1 2"
scenario "filter-chain counter missing after"    phase1 "envoy: no_filter_chain_match" FAIL SCEN_NFCM="1 missing"
scenario "OpenAPI lists both paths"              phase2 "api: OpenAPI lists"           PASS
scenario "OpenAPI without /orders"               phase2 "api: OpenAPI lists"           FAIL \
  SCEN_OPENAPI='{"info":{"title":"orders-api"},"paths":{"/orders/{order_id}":{},"/admin/chaos":{}}}'
scenario "order processed, 1 event sent"         phase3 "flow: order"                  PASS
scenario "order processed, 10 events sent"       phase3 "flow: order"                  FAIL SCEN_EVENTS=10
scenario "worker counter 2.0"                    phase3 "worker: processed counter"    PASS
scenario "worker counter 0.0"                    phase3 "worker: processed counter"    FAIL SCEN_WORKER=0.0
scenario "MQ SAN failures 0"                     phase3 "envoy: MQ certificate name"   PASS
scenario "MQ SAN failures 10"                    phase3 "envoy: MQ certificate name"   FAIL SCEN_SAN=10
scenario "MQ SAN counter missing"                phase3 "envoy: MQ certificate name"   FAIL SCEN_SAN=missing
scenario "no order after the Postgres restart"   phase5 "postgres restart"             FAIL SCEN_ORDERS=down
scenario "an order after the Postgres restart"   phase5 "postgres restart"             PASS

out="$(PATH="${work}/stub:${PATH}" bash "${work}/demo/scripts/verify.sh" phase4 2>&1)"; status=$?
if [ "${status}" -ne 0 ]; then verdict=ok; else verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
printf '%-9s %-46s exit %s (want non-zero): %s\n' "${verdict}" "unknown phase name phase4" "${status}" "$(tail -1 <<<"${out}")"

# verify.sh's own prometheus_value against the fake curl: a fresh sample is read as it is, and an
# empty answer (no fresh scrape) fails rather than become a zero the next cumulative sample would
# look past. The first case also proves the function was found and runs, so a missing or always
# failing function cannot pass the second.
prometheus_function="$(awk '/^prometheus_value\(\)/ { on=1 } on { print } on && /^}/ { exit }' "${work}/demo/scripts/verify.sh")"
prometheus_case() {  # prometheus_case <name> <want: a value, or "fail"> [VAR=value ...]
  local name="$1" want="$2" out status got verdict=ok
  shift 2
  out="$(env PATH="${work}/stub:${PATH}" "$@" bash -o pipefail -c "${prometheus_function}
prometheus_value" 2>/dev/null)"; status=$?
  if [ "${status}" -eq 0 ]; then got="${out}"; else got=fail; fi
  if [ -z "${prometheus_function}" ] || [ "${got}" != "${want}" ]; then verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
  printf '%-9s %-46s %s (want %s)\n' "${verdict}" "${name}" "${got}" "${want}"
}
prometheus_case "Prometheus answers 20: read as 20"          20   SCEN_PROM_VALUE=20
prometheus_case "Prometheus answers empty: no zero invented" fail SCEN_PROM_EMPTY=1

# Exercise the two phase6 verdict functions directly. Positive controls prove each function was
# found and can pass; unequal, zero and missing inputs prove it cannot pass vacuously.
# The single quotes intentionally preserve $1, $2 and arithmetic for the nested test shell.
# shellcheck disable=SC2016
verdict_prelude='FAILURES=0
pass() { printf "PASS  %-46s %s\\n" "$1" "$2"; }
fail() { printf "FAIL  %-46s %s\\n" "$1" "$2"; FAILURES=$((FAILURES + 1)); }'
verdict_function() {  # verdict_function <function name>
  awk -v function_name="$1" '$0 ~ "^" function_name "\\(\\)" { on=1 } on { print } on && /^}/ { exit }' \
    "${work}/demo/scripts/verify.sh"
}
phase6_case() {  # phase6_case <name> <function> <check name> <want> <arguments...>
  local name="$1" function_name="$2" check_name="$3" want="$4" function_text out got verdict=ok
  shift 4
  function_text="$(verdict_function "${function_name}")"
  out="$(bash -c "${verdict_prelude}
${function_text}
${function_name} \"\$@\"" _ "$@" 2>&1)"
  got="$(grep -E "^(PASS|FAIL)  ${check_name}" <<<"${out}" | head -1 | cut -c1-4)"
  if [ -z "${function_text}" ] || [ "${got}" != "${want}" ]; then verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
  printf '%-9s %-46s %s (want %s)\n' "${verdict}" "${name}" "${got:-none}" "${want}"
}
phase6_case "span counts 2 and 2" trace_span_verdict "stores: one trace has two spans" PASS 2 2
phase6_case "span counts 2 and 1" trace_span_verdict "stores: one trace has two spans" FAIL 2 1
phase6_case "span counts 0 and 0" trace_span_verdict "stores: one trace has two spans" FAIL 0 0
phase6_case "span count missing" trace_span_verdict "stores: one trace has two spans" FAIL "" 2
jobs='envoy mq orders-api otel-collector postgres tcp-svc tempo victoria-logs victoria-metrics victoria-traces worker'
phase6_case "healthy job sets equal" scrape_jobs_verdict "stores: same healthy scrape jobs" PASS 11 "${jobs}" "${jobs}"
phase6_case "VictoriaMetrics misses one job" scrape_jobs_verdict "stores: same healthy scrape jobs" FAIL 11 "${jobs}" "${jobs% worker}"
echo "mismatches: ${mismatches}"; exit "${mismatches}"
