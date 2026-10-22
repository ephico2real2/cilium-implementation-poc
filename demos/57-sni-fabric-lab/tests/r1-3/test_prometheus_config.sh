#!/usr/bin/env bash
# Usage: test_prometheus_config.sh
# Prometheus must accept its committed scrape-and-remote-write config; the negative control
# corrupts remote_write itself so a check that ignores the new block cannot pass.
set -u

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEMO_DIR
readonly CONFIG="${DEMO_DIR}/observability/prometheus.yml"
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

podman run --rm --entrypoint /bin/promtool \
  -v "${CONFIG}:/etc/prometheus/prometheus.yml:ro" "${PROM_IMAGE}" \
  check config /etc/prometheus/prometheus.yml >"${work}/valid.out" 2>&1
case_result "promtool accepts the committed config" pass "$?"

python3 - "${CONFIG}" "${work}/bad-remote-write.yml" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = "url: http://victoriametrics.mesh:18080/api/v1/write"
if source.count(needle) != 1:
    raise SystemExit("expected exactly one committed remote_write URL")
Path(sys.argv[2]).write_text(source.replace(needle, "url: [", 1))
PY
case_result "negative control found the committed remote_write" pass "$?"

podman run --rm --entrypoint /bin/promtool \
  -v "${work}/bad-remote-write.yml:/etc/prometheus/prometheus.yml:ro" "${PROM_IMAGE}" \
  check config /etc/prometheus/prometheus.yml >"${work}/invalid.out" 2>&1
case_result "promtool rejects malformed remote_write (negative control)" fail "$?"

echo "mismatches: ${bad}"
exit "${bad}"
