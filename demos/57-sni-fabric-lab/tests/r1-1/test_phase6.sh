#!/usr/bin/env bash
# Usage: test_phase6.sh <path to verify.sh>. Runs phase6 against fake podman/curl/sleep in four
# scenarios; exits non-zero if any check's verdict differs from the correct one.
set -u
H="$(cd "$(dirname "$0")" && pwd)"
demo="$(mktemp -d "${H}/demo.XXXX")"; mkdir -p "${demo}/scripts" "${demo}/certs/ca"
cp "$1" "${demo}/scripts/verify.sh"; echo dummy > "${demo}/certs/ca/ca.crt"
ok_tg="${H}/tg-ok.txt"; bad_tg="${H}/tg-bad.txt"
printf '2026-10-21T23:36:14Z\tINFO\ttraces/worker.go:180\ttraces generated\t{"worker": 0, "traces": 5}\n' > "${ok_tg}"
{ cat "${ok_tg}"; echo '2026/10/21 23:36:15 traces export: failed to send to http://otlp.mesh:18080/v1/traces: 503 Service Unavailable'; } > "${bad_tg}"
mismatches=0
scenario() {  # scenario <name> <values> <tg output> <internal> <expected otel> <expected isolation>
  local state; state="$(mktemp "${H}/state.XXXX")"; echo 0 > "${state}"
  local out; out="$(PATH="${H}/stub:${PATH}" SCEN_STATE="${state}" SCEN_VALUES="$2" SCEN_TG_OUT="$3" SCEN_INTERNAL="$4" \
    bash "${demo}/scripts/verify.sh" phase6 2>&1)"
  local otel iso; otel="$(grep -oE '^(PASS|FAIL)  otel:' <<<"${out}" | cut -c1-4)"; iso="$(grep -oE '^(PASS|FAIL)  isolation:' <<<"${out}" | cut -c1-4)"
  local verdict=ok; [ "${otel}" = "$5" ] && [ "${iso}" = "$6" ] || { verdict=MISMATCH; mismatches=$((mismatches + 1)); }
  printf '%-9s %-44s otel=%s (want %s) isolation=%s (want %s)\n' "${verdict}" "$1" "${otel}" "$5" "${iso}" "$6"
  rm -f "${state}"
}
scenario "healthy run, 10 spans arrive"              "10 20" "${ok_tg}"  true  PASS PASS
scenario "3 of 5 traces arrive (6 spans), 503s logged" "0 6"   "${bad_tg}" true  FAIL PASS
scenario "exports fail, another sender adds 30"      "10 40" "${bad_tg}" true  FAIL PASS
scenario "net-otel not internal"                     "10 20" "${ok_tg}"  false PASS FAIL
rm -rf "${demo}" "${ok_tg}" "${bad_tg}"
echo "mismatches: ${mismatches}"; exit "${mismatches}"
