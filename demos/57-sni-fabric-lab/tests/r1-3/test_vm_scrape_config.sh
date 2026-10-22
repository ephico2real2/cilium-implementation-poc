#!/usr/bin/env bash
# Usage: test_vm_scrape_config.sh
# VictoriaMetrics and Prometheus must accept their one shared scrape file; the negative control
# puts the unsupported rule-evaluation key back so a permissive or vacuous test cannot pass.
set -u

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEMO_DIR
readonly CONFIG="${DEMO_DIR}/observability/prometheus.yml"
readonly VM_IMAGE="docker.io/victoriametrics/victoria-metrics:v1.153.0"
readonly PROM_IMAGE="docker.io/prom/prometheus:v3.15.0"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
bad=0

case_result() {  # case_result <name> <want status: pass|fail> <actual status>
  local name="$1" want="$2" status="$3"
  if { [ "${want}" = pass ] && [ "${status}" -eq 0 ]; } || \
     { [ "${want}" = fail ] && [ "${status}" -ne 0 ]; }; then
    printf 'ok        %s\n' "${name}"
  else
    printf 'MISMATCH  %s (exit %s, want %s)\n' "${name}" "${status}" "${want}"
    bad=$((bad + 1))
  fi
}

podman run --rm -v "${CONFIG}:/etc/prometheus/prometheus.yml:ro" "${VM_IMAGE}" \
  -promscrape.config=/etc/prometheus/prometheus.yml -promscrape.config.dryRun \
  >"${work}/vm-valid.out" 2>&1
case_result "VictoriaMetrics accepts the committed scrape config" pass "$?"

# Insert the key under global, where Prometheus accepts it and VictoriaMetrics' strict parser must not.
awk '{ print; if ($0 == "global:") print "  evaluation_interval: 10s" }' "${CONFIG}" \
  >"${work}/with-evaluation-interval.yml"
podman run --rm -v "${work}/with-evaluation-interval.yml:/etc/prometheus/prometheus.yml:ro" \
  "${VM_IMAGE}" -promscrape.config=/etc/prometheus/prometheus.yml \
  -promscrape.config.dryRun >"${work}/vm-invalid.out" 2>&1
case_result "VictoriaMetrics rejects evaluation_interval (negative control)" fail "$?"

podman run --rm --entrypoint /bin/promtool \
  -v "${CONFIG}:/etc/prometheus/prometheus.yml:ro" "${PROM_IMAGE}" \
  check config /etc/prometheus/prometheus.yml >"${work}/promtool.out" 2>&1
case_result "promtool accepts the committed scrape config" pass "$?"

echo "mismatches: ${bad}"
exit "${bad}"
