#!/usr/bin/env bash
# Usage: test_verify_false_pass.sh <path to verify.sh>
# Runs verify.sh against a fake podman, curl and openssl (nothing touches the lab, phase5's
# stop and restart included) and checks that each check below gives the right verdict:
# no number may pass by being a substring of another, no missing value may pass, and an
# unknown phase name must not exit 0 with "failures: 0".
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
      *no_filter_chain_match) echo "${stat}: $(next nfcm "${SCEN_NFCM}")" ;;
      *fail_verify_san) [ "${SCEN_SAN}" = missing ] || echo "${stat}: ${SCEN_SAN}" ;;
      *) echo "${stat}: $(next "${stat}" "1 50")" ;;
    esac ;;
  "exec fabric-orders-api-1")
    for i in $(seq 1 12); do echo "sample_${i} 1"; done
    echo 'worker_messages_total{result="processed"} 2.0'
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
case "${method} ${url}" in
  *"/admin/overview")
    body='{"health":[{"name":"envoy","ok":true},{"name":"postgres","ok":true},{"name":"web","ok":true},{"name":"tcp-svc","ok":true},{"name":"mq","ok":true},{"name":"worker","ok":true}]}' ;;
  "POST "*"/orders")
    if [ "${SCEN_ORDERS}" = down ]; then code=000; else code=201; body='{"id":7,"item":"espresso","quantity":2,"status":"created","events_sent":0}'; fi ;;
  "GET "*/orders/[0-9]*) body='{"id":7,"item":"espresso","quantity":2,"status":"processed","events_sent":1}' ;;
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
scenario "filter-chain misses 1 -> 13"           phase1 "envoy: no_filter_chain_match" FAIL SCEN_NFCM="1 13"
scenario "MQ SAN failures 0"                     phase3 "envoy: MQ certificate name"   PASS
scenario "MQ SAN failures 10"                    phase3 "envoy: MQ certificate name"   FAIL SCEN_SAN=10
scenario "MQ SAN counter missing"                phase3 "envoy: MQ certificate name"   FAIL SCEN_SAN=missing
scenario "no order after the Postgres restart"   phase5 "postgres restart"             FAIL SCEN_ORDERS=down
scenario "an order after the Postgres restart"   phase5 "postgres restart"             PASS

out="$(PATH="${work}/stub:${PATH}" bash "${work}/demo/scripts/verify.sh" phase4 2>&1)"; status=$?
if [ "${status}" -ne 0 ]; then verdict=ok; else verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
printf '%-9s %-46s exit %s (want non-zero): %s\n' "${verdict}" "unknown phase name phase4" "${status}" "$(tail -1 <<<"${out}")"
echo "mismatches: ${mismatches}"; exit "${mismatches}"
