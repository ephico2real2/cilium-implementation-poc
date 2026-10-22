#!/usr/bin/env bash
# Usage: test_run_sh.sh <path to run.sh>
# Runs run.sh against a fake podman and stub steps; exits non-zero if
# run.sh's verdict differs from the right one:
#   - a failed "compose up" must stop the run before any check, even while old containers
#     still answer healthy (they would otherwise be checked in place of the new build);
#   - "--fresh" on a lab that never ran (compose down removes nothing) must go on;
#   - a healthy run must pass;
#   - a bind-mounted file newer than its containers recreates exactly those services;
#   - a newer file below a bind-mounted directory recreates that service, while old sources do not;
#   - a file deleted from a bind-mounted directory recreates that service (the directory's mtime);
#   - parity runs after phase 6 and before phase 5, whose outages leave gaps it cannot compare;
#   - with --random secrets, the committed transcript must not hold them (the public lab
#     values it prints by design).
set -u
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/stub"
cat > "${work}/stub/podman" <<'STUB'
#!/usr/bin/env bash
# Fake podman: answers only the calls run.sh makes.
case "$1 $2" in
  "compose down")
    # docker compose v5.5.1 pkg/compose/down.go:138, for a project with nothing to remove.
    echo 'level=warning msg="Warning: No resource found to remove for project \"fabric\"."' >&2 ;;
  "compose up")
    if [ "${SCEN_UP_FAIL:-0}" = 1 ]; then echo "Error: building orders-api: exit status 1" >&2; exit 1; fi
    if [[ " $* " == *" --force-recreate "* ]]; then
      services=(); after_no_deps=0
      for argument in "$@"; do
        if [ "${after_no_deps}" = 1 ]; then services+=("${argument}"); fi
        [ "${argument}" != --no-deps ] || after_no_deps=1
      done
      printf '%s\n' "${services[*]}" > "${SCEN_DEMO}/recreated"
    fi
    echo " Container fabric-envoy-1 Started" ;;
  "compose config")
    python3 - "${SCEN_DEMO}" <<'PY'
import json, sys
root = sys.argv[1]
print(json.dumps({"services": {
    "envoy": {"volumes": [{"type": "bind", "source": root + "/mounted.yml", "target": "/one"}]},
    "web": {"volumes": [{"type": "bind", "source": root + "/mounted.yml", "target": "/two"}]},
    "grafana": {"volumes": [{"type": "bind", "source": root + "/mounted-dir", "target": "/dir"}]},
}}))
PY
    ;;
  "inspect "*)
    if [[ "$*" == *'{{.Created.UnixNano}}'* ]]; then
      printf '1767225600000000000\t2026-01-01T00:00:00Z\n'
    else
      echo healthy
    fi ;;
  "stats --no-stream") echo "fabric-envoy-1 24MB / 4GB" ;;
  *) echo "fake podman: unexpected: $*" >&2; exit 99 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/stub/sleep"
chmod +x "${work}/stub/podman" "${work}/stub/sleep"

mismatches=0
scenario() {  # scenario <name> <run.sh args> <up fail> <want> <mount> <recreated> <parity> <window>
  local demo out status checks verdict=ok got recreated parity_attempts window_attempts
  demo="$(mktemp -d "${work}/demo.XXXX")"
  mkdir -p "${demo}/scripts" "${demo}/tests/r1-2" "${demo}/secrets"
  printf 'mounted file\n' > "${demo}/mounted.yml"
  mkdir -p "${demo}/mounted-dir"
  printf 'mounted directory file\n' > "${demo}/mounted-dir/value"
  touch -t 202501010000 "${demo}/mounted.yml" "${demo}/mounted-dir/value" "${demo}/mounted-dir"
  case "$5" in
    file) touch -t 202701010000 "${demo}/mounted.yml" ;;
    directory) touch -t 202701010000 "${demo}/mounted-dir/value" ;;
    deleted) rm "${demo}/mounted-dir/value" ;;
    none) ;;
    *) echo "test_run_sh: unknown mount mode: $5" >&2; exit 2 ;;
  esac
  # Process substitution is forbidden by some managed test sandboxes. This harness tests run.sh's
  # control flow, not tee, so replace only its transcript tee with a plain redirection.
  awk '
    $0 == "exec > >(tee \"${TRANSCRIPT}\") 2>&1" {
      print "exec >\"${TRANSCRIPT}\" 2>&1"
      next
    }
    { print }
  ' "${RUN_SH}" > "${demo}/scripts/run.sh"
  printf '#!/usr/bin/env bash\necho gen-certs.sh\n' > "${demo}/scripts/gen-certs.sh"
  # The real gen-secrets.sh: it keeps the files below and is where the lab values are listed.
  cp "$(dirname "${RUN_SH}")/gen-secrets.sh" "${demo}/scripts/gen-secrets.sh"
  printf '#!/usr/bin/env bash\necho "verify $*" >> "%s/checks"\necho "verify $*" >> "%s/order"\n' \
    "${demo}" "${demo}" > "${demo}/scripts/verify.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${demo}/tests/r1-2/test_store_routes.sh"
  cat > "${demo}/tests/parity.py" <<'PY'
import os
from pathlib import Path
import sys

if "--window-ready" in sys.argv:
    if os.environ.get("SCEN_DEMO"):
        path = Path(os.environ["SCEN_DEMO"]) / "window-attempts"
        count = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(count))
    print("rate window samples at T: Prometheus=30, VictoriaMetrics=30; need at least 30")
    raise SystemExit(1 if os.environ.get("SCEN_WINDOW") == "fail" else 0)
# The rerun below the scenarios sets no SCEN_DEMO; only the scenarios record the step order.
if os.environ.get("SCEN_DEMO"):
    with open(Path(os.environ["SCEN_DEMO"]) / "order", "a", encoding="utf-8") as order:
        order.write("parity\n")
# band: a disagreement that lasts until the gate is passed again (an outage at a window's edge).
gate_reads = Path(os.environ.get("SCEN_DEMO", "/nonexistent")) / "window-attempts"
if (os.environ.get("SCEN_PARITY") == "band"
        and int(gate_reads.read_text() if gate_reads.exists() else "0") < 2):
    print("10 queries, 1 disagreements")
    raise SystemExit(1)
if os.environ.get("SCEN_PARITY") == "fail":
    path = Path(os.environ["SCEN_DEMO"]) / "parity-attempts"
    count = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(count))
    print("10 queries, 1 disagreements")
    raise SystemExit(1)
else:
    print("10 queries, 0 disagreements")
PY
  printf 'print("31 queries, 0 with errors or warnings, 0 empty")\n' > "${demo}/tests/dashboard_queries.py"
  printf 'pass\n' > "${demo}/tests/test_dashboard.py"
  chmod +x "${demo}"/scripts/*.sh
  for s in admin-token mq-admin-password mq-app-password grafana-admin-password postgres-password; do
    printf '%s' "${SECRET_PREFIX:-x}-$s" > "${demo}/secrets/$s"
  done
  # shellcheck disable=SC2086
  out="$(PATH="${work}/stub:${PATH}" SCEN_UP_FAIL="$3" SCEN_DEMO="${demo}" SCEN_PARITY="$7" SCEN_WINDOW="$8" \
    bash "${demo}/scripts/run.sh" $2 2>&1)"; status=$?
  checks=0; [ ! -f "${demo}/checks" ] || checks="$(wc -l < "${demo}/checks")"
  if [ "${status}" -eq 0 ]; then got=pass; else got=stop; fi
  [ "${got}" = "$4" ] || { verdict=MISMATCH; mismatches=$((mismatches + 1)); }
  # A failed compose start must not have reached a single check.
  if [ "$3" = 1 ] && [ "${checks}" -ne 0 ]; then verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
  recreated="$(cat "${demo}/recreated" 2>/dev/null || true)"
  if [ "${recreated}" != "$6" ]; then verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
  parity_attempts="$(cat "${demo}/parity-attempts" 2>/dev/null || true)"
  if [ "$7" = fail ] && [ "${parity_attempts}" != 2 ]; then
    verdict=MISMATCH; mismatches=$((mismatches + 1))
  fi
  window_attempts="$(cat "${demo}/window-attempts" 2>/dev/null || true)"
  if [ "$8" = fail ] && { [ "${window_attempts}" != 72 ] ||
       ! grep -Fq 'timed out after 72 window checks and 355s retry sleep' "${demo}/output/transcript.txt"; }; then
    verdict=MISMATCH; mismatches=$((mismatches + 1))
  fi
  order="$(paste -sd '|' "${demo}/order" 2>/dev/null || true)"
  want_order="verify phase1 phase2 phase3|verify phase6|parity|verify phase5"
  [ "$7" != band ] || want_order="verify phase1 phase2 phase3|verify phase6|parity|parity|verify phase5"
  if [ "${got}" = pass ] && [ "${order}" != "${want_order}" ]; then
    verdict=MISMATCH; mismatches=$((mismatches + 1)); echo "          order: ${order}"
  fi
  printf '%-9s %-52s exit=%s (%s, want %s), verify runs=%s, recreated=[%s]\n' \
    "${verdict}" "$1" "${status}" "${got}" "$4" "${checks// /}" "${recreated}"
  [ "${verdict}" = ok ] || grep -E '^(objects removed|Error|timed out)' <<<"${out}" | sed 's/^/          /'
}
RUN_SH="$1"
scenario "compose up fails while old containers are healthy" ""        1 stop none "" pass pass
scenario "--fresh on a lab that never ran"                   "--fresh" 0 pass none "" pass pass
scenario "healthy run; old bind sources"                     ""        0 pass none "" pass pass
scenario "new bind-mounted file"                             ""        0 pass file "envoy web" pass pass
scenario "new file in bind-mounted directory"                ""        0 pass directory "grafana" pass pass
scenario "file deleted from bind-mounted directory"          ""        0 pass deleted "grafana" pass pass
scenario "two persistent parity disagreements"               ""        0 stop none "" fail pass
scenario "rate comparison never becomes ready"               ""        0 stop none "" pass fail
scenario "parity disagrees until the gate passes again"      ""        0 pass none "" band pass

# The transcript must hold no --random value, and still print the public lab values.
leaks=0
rm -rf "${work}"/demo.*
SECRET_PREFIX="rNd0m7Qx" scenario "run with random secrets" "" 0 pass none "" pass pass >/dev/null
random_lines="$(cat "${work}"/demo.*/output/transcript.txt | grep -c 'rNd0m7Qx')"
rm -rf "${work}"/demo.*
SECRET_PREFIX="unused" scenario "run with the lab values" "" 0 pass none "" pass pass >/dev/null
for d in "${work}"/demo.*; do  # rewrite the lab values gen-secrets.sh lists, then run again
  for kv in admin-token=fabric-admin postgres-password=fabric-postgres; do printf '%s' "${kv#*=}" > "${d}/secrets/${kv%%=*}"; done
  PATH="${work}/stub:${PATH}" bash "${d}/scripts/run.sh" >/dev/null 2>&1
  lab_shown="$(grep -c -E 'token  fabric-admin|fabric / fabric-postgres' "${d}/output/transcript.txt")"
done
if [ "${random_lines}" -eq 0 ]; then echo "ok        random secrets kept out of the transcript"; else echo "MISMATCH  random secrets: ${random_lines} transcript line(s) hold one"; leaks=1; fi
if [ "${lab_shown}" -eq 2 ]; then echo "ok        public lab values still printed"; else echo "MISMATCH  public lab values printed: ${lab_shown} of 2"; leaks=1; fi
mismatches=$((mismatches + leaks))
echo "mismatches: ${mismatches}"; exit "${mismatches}"
