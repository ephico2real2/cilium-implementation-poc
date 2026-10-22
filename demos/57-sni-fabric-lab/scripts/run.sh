#!/usr/bin/env bash
# Builds the lab from nothing and checks it, recording everything to output/transcript.txt.
#
# Usage: scripts/run.sh [--fresh] [-h|--help]
#   --fresh      first remove the lab's containers and volumes (podman compose down -v):
#                a rebuild from nothing; Postgres, MQ, Prometheus, Grafana and the telemetry
#                stores' data are lost
#   -h, --help   print this help
# Takes about 8 minutes (8 min 6 s recorded): MQ starts in about 2 under amd64 emulation,
# and phase 6 waits up to 90 s for the stores to show new data. Exits non-zero at the first
# failed step.
# Steps: certificates, secrets, images and containers, wait for every health check, then
# scripts/verify.sh (phases 1-3), phase 6, the store route test, the dashboard tests, and phase 5
# (failure and recovery).
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

step "Check that Envoy refuses the stores' admin and write paths"
bash tests/r1-2/test_store_routes.sh

step "Check the dashboard: every query, both forms"
python3 tests/dashboard_queries.py --minutes 5 | grep -E "^(EMPTY|ERROR)|queries,"
python3 tests/test_dashboard.py

step "Check failures and recovery (phase 5)"
scripts/verify.sh phase5

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
Postgres        (through Envoy only)                                  fabric / $(cred postgres-password)
EOF

step "Done"
