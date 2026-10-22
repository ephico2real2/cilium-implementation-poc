#!/usr/bin/env bash
# Builds the lab from nothing and checks it, recording everything to output/transcript.txt.
#
# Usage: scripts/run.sh [--fresh] [-h|--help]
#   --fresh      first remove the lab's containers and volumes (podman compose down -v):
#                a rebuild from nothing; Postgres, MQ, Prometheus, Grafana and the telemetry
#                stores' data are lost
#   -h, --help   print this help
# Takes about 11 minutes (11 min 1 s recorded): MQ starts in about 2 under amd64 emulation,
# phase 6 waits up to 90 s for the stores to show new data, and parity waits until every selected
# rate's exact cross-engine value is comparable. Exits non-zero at the first failed step.
# Steps: certificates, secrets, images and containers, wait for every health check, then
# scripts/verify.sh (phases 1-3), phase 6, store parity, phase 5 (failure and recovery), the
# store routes, and the dashboard tests.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEMO_DIR
readonly TRANSCRIPT="${DEMO_DIR}/output/transcript.txt"
# Services with a health check; tempo, victoria-traces and victoria-logs have none (distroless
# images), so phase 6 waits for their readiness through Envoy instead.
readonly SERVICES="envoy web tcp-svc orders-api postgres mq worker prometheus grafana victoria-metrics"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --fresh|"") ;;
  *) echo "run: unknown argument: $1" >&2; exit 1 ;;
esac

mkdir -p "${DEMO_DIR}/output"
exec > >(tee "${TRANSCRIPT}") 2>&1
cd "${DEMO_DIR}"

step() { printf '\n==== %s  (%s)\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# The filter only drops noise and may select nothing; the pipeline's status is podman's own.
compose() { podman compose "$@" 2>&1 | { grep -v -E '>>>>|Executing external compose provider|^\s*$|^\[0m$' || true; }; }
bounded_retry() {  # bounded_retry <attempts> <delay seconds> <command...>
  local attempts="$1" delay="$2" attempt out status
  shift 2
  for attempt in $(seq 1 "${attempts}"); do
    if out="$("$@" 2>&1)"; then
      printf '%s\n' "${out}"
      return 0
    else
      status=$?
    fi
    printf '%s\n' "${out}"
    [ "${attempt}" -lt "${attempts}" ] || return "${status}"
    echo "retry ${attempt}/${attempts}: waiting ${delay}s for telemetry ingestion"
    sleep "${delay}"
  done
}

recreate_stale_bind_mounts() {
  local config stale service source newest created
  local -a stale_services=()
  config="$(mktemp)"
  stale="$(mktemp)"
  podman compose config --format json >"${config}"
  python3 - "${config}" "${DEMO_DIR}" >"${stale}" <<'PY'
import json
import os
import subprocess
import sys

config_path, project_dir = sys.argv[1:]
services = json.load(open(config_path, encoding="utf-8")).get("services", {})


def newest_mtime(source: str) -> float | None:
    try:
        newest = os.stat(source).st_mtime
    except FileNotFoundError:
        return None
    if not os.path.isdir(source):
        return newest
    for root, directories, files in os.walk(source):
        for name in directories + files:
            try:
                newest = max(newest, os.stat(os.path.join(root, name)).st_mtime)
            except FileNotFoundError:  # A generated file can disappear while config is inspected.
                pass
    return newest


for service, definition in services.items():
    binds = [volume for volume in definition.get("volumes", [])
             if isinstance(volume, dict) and volume.get("type") == "bind"]
    if not binds:
        continue
    inspected = subprocess.run(
        ["podman", "inspect", f"fabric-{service}-1", "--format",
         "{{.Created.UnixNano}}\t{{.Created}}"],
        check=False, text=True, capture_output=True)
    if inspected.returncode != 0:  # Profiles and services that are not running need no recreation.
        continue
    created_ns, separator, created_text = inspected.stdout.strip().partition("\t")
    if not separator:
        raise SystemExit(f"cannot read fabric-{service}-1 creation time: {inspected.stdout!r}")
    try:
        created = int(created_ns) / 1_000_000_000
    except ValueError as error:
        raise SystemExit(f"cannot parse fabric-{service}-1 creation epoch {created_ns!r}: {error}")
    for volume in binds:
        source = os.path.abspath(os.path.join(project_dir, volume["source"])) \
            if not os.path.isabs(volume["source"]) else volume["source"]
        newest = newest_mtime(source)
        if newest is not None and newest > created:
            print(f"{service}\t{source}\t{newest:.6f}\t{created_text}")
PY
  while IFS=$'\t' read -r service source newest created; do
    [ -n "${service}" ] || continue
    printf 'recreate %-16s bind source newer than container: %s (mtime %s > created %s)\n' \
      "${service}" "${source}" "${newest}" "${created}"
    case " ${stale_services[*]} " in
      *" ${service} "*) ;;
      *) stale_services+=("${service}") ;;
    esac
  done <"${stale}"
  rm -f "${config}" "${stale}"
  if [ "${#stale_services[@]}" -eq 0 ]; then
    echo "bind mounts: no running service has a newer source"
    return
  fi
  # A bind keeps its old inode across a checkout, so Compose must recreate these exact services.
  compose up -d --force-recreate --no-deps "${stale_services[@]}" \
    | { grep -E 'Started|Recreated|Error' || true; }
}

wait_for_rate_window() {  # wait_for_rate_window <attempts> <delay seconds>
  local attempts="$1" delay="$2" attempt out status
  for attempt in $(seq 1 "${attempts}"); do
    if out="$(python3 tests/parity.py --window-ready 2>&1)"; then
      printf '%s\n' "${out}"
      return 0
    else
      status=$?
    fi
    printf '%s\n' "${out}"
    if [ "${attempt}" -ge "${attempts}" ]; then
      echo "timed out after ${attempts} window checks and $(((attempts - 1) * delay))s retry sleep"
      return "${status}"
    fi
    echo "window ${attempt}/${attempts}: waiting ${delay}s for every rate to become comparable"
    sleep "${delay}"
  done
}

parity_with_ingestion_retry() {
  local out status
  if out="$(python3 tests/parity.py 2>&1)"; then
    printf '%s\n' "${out}"
    return 0
  else
    status=$?
  fi
  printf '%s\n' "${out}"
  # One retry, after the gate passes again: it outlasts remote-write lag, and a target outage
  # still crossing a window edge (a rerun soon after the last run's phase 5, 6-70 s measured)
  # holds the gate instead of failing parity twice in five seconds.
  echo "parity disagreement: retrying once, when every rate is comparable again"
  wait_for_rate_window 72 5 || return "${status}"
  python3 tests/parity.py || return "${status}"
}

if [ "${1:-}" = "--fresh" ]; then
  step "Remove the lab's containers and volumes"
  # grep -c exits 1 when it counts nothing (a lab that never ran): that is not a failure.
  compose down -v --remove-orphans | { grep -c -E 'Removed' || true; } | sed 's/^/objects removed: /'
fi

step "Create the CA and certificates"
scripts/gen-certs.sh

step "Create the secrets"
scripts/gen-secrets.sh

step "Build and start every container"
# A failed build or start stops the run here, before stale containers can pass the checks.
compose up -d --build | { grep -E 'Started|Built|Error' || true; }

step "Recreate services whose bind-mounted source changed"
recreate_stale_bind_mounts

step "Wait for every health check"
started=${SECONDS}
for service in ${SERVICES}; do
  until [ "$(podman inspect "fabric-${service}-1" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; do
    [ $((SECONDS - started)) -lt 600 ] || { echo "timed out waiting for ${service}"; exit 1; }
    sleep 3
  done
  printf '%-16s healthy after %ss\n' "${service}" "$((SECONDS - started))"
done

step "Check phases 1-3"
scripts/verify.sh phase1 phase2 phase3

step "Check the collector and the telemetry stores (phase 6)"
scripts/verify.sh phase6

step "Compare Prometheus and VictoriaMetrics, then run every dashboard query on VictoriaMetrics"
# Before phase 5: across a target's outage the engines can differ by design, so the gate waits
# until every selected rate matches its exact cross-engine equivalent. Parity then gets one
# retry, after the gate passes again.
wait_for_rate_window 72 5
parity_with_ingestion_retry
bounded_retry 12 5 python3 tests/dashboard_queries.py \
  --prometheus http://victoriametrics.fabric.localtest.me:8080 --minutes 5

step "Check failures and recovery (phase 5)"
scripts/verify.sh phase5

step "Check the stores' allowed routes and refused admin or host-write paths"
bash tests/r1-2/test_store_routes.sh

step "Check the dashboard: every query, both forms"
python3 tests/dashboard_queries.py --minutes 5 | grep -E "^(EMPTY|ERROR)|queries,"
python3 tests/test_dashboard.py

step "Memory in use"
podman stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep '^fabric-' | sort

# A credential is printed only when it is the public lab value in gen-secrets.sh: a --random
# value stays in secrets/, out of the transcript, which is committed.
cred() {  # cred <file in secrets/>
  local value
  value="$(cat "secrets/$1")"
  if grep -qxF -- "$1=${value}" scripts/gen-secrets.sh; then printf '%s' "${value}"; else printf '(random: secrets/%s)' "$1"; fi
}

step "Where to log in (lab credentials, from secrets/)"
cat <<EOF
Orders page     https://web.fabric.localtest.me:8443/
Admin portal    https://web.fabric.localtest.me:8443/admin            token  $(cred admin-token)
Swagger         https://api.fabric.localtest.me:8443/docs
MQ console      https://mqconsole.fabric.localtest.me:8443/ibmmq/console  admin / $(cred mq-admin-password)
MQ app user     (REST API, MQ clients)                                app / $(cred mq-app-password)
Grafana         http://grafana.fabric.localtest.me:8080              anonymous viewer; admin / $(cred grafana-admin-password)
Prometheus      http://prometheus.fabric.localtest.me:8080
VictoriaMetrics http://victoriametrics.fabric.localtest.me:8080/vmui/ none
Postgres        (through Envoy only)                                  fabric / $(cred postgres-password)
EOF

step "Done"
