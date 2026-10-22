#!/usr/bin/env bash
# Usage: test_prometheus_baseline.sh <path to verify.sh>   (needs podman and the lab's
# docker.io/prom/prometheus:v3.15.0 image; starts nothing of the lab's)
# phase6 reads verify.sh's prometheus_value before and after it sends spans, and passes when the
# difference covers them. This runs that function, unchanged, against two throwaway Prometheus
# servers whose job "otel-collector" exposes no span counter:
#   - the target answers (up 1): the counter does not exist yet, so the baseline is 0;
#   - the target is down (up 0): nothing is known of the counter, so the baseline must fail
#     rather than read 0, or a counter that reappears later passes as the spans just sent.
set -u
image=docker.io/prom/prometheus:v3.15.0
work="$(mktemp -d)"
containers=()
trap '[ "${#containers[@]}" -eq 0 ] || podman rm -f "${containers[@]}" >/dev/null 2>&1; rm -rf "${work}"' EXIT

function_text="$(awk '/^prometheus_value\(\)/ { on=1 } on { print } on && /^}/ { exit }' "$1")"
[ -n "${function_text}" ] || { echo "prometheus_value() not found in $1"; exit 1; }

# The function asks prometheus.fabric.localtest.me:8080; this curl sends it to the server under test.
mkdir -p "${work}/bin"
cat > "${work}/bin/curl" <<STUB
#!/usr/bin/env bash
args=()
for arg in "\$@"; do args+=("\${arg/http:\/\/prometheus.fabric.localtest.me:8080/http://127.0.0.1:\${PROM_PORT}}"); done
exec "$(command -v curl)" "\${args[@]}"
STUB
chmod +x "${work}/bin/curl"

start() {  # start <target>  -> sets port: a Prometheus scraping <target> every 2 s as job otel-collector
  local dir name
  dir="$(mktemp -d "${work}/prom.XXXX")"
  name="test-prometheus-baseline-$$-${#containers[@]}"
  printf 'global: {scrape_interval: 2s}\nscrape_configs:\n  - job_name: otel-collector\n    static_configs: [{targets: ["%s"]}]\n' \
    "$1" > "${dir}/prometheus.yml"
  chmod 755 "${dir}"; chmod 644 "${dir}/prometheus.yml"
  podman run -d --rm --name "${name}" -p 127.0.0.1::9090 -v "${dir}:/cfg:ro" "${image}" \
    --config.file=/cfg/prometheus.yml >/dev/null || return 1
  containers+=("${name}")
  port="$(podman port "${name}" 9090/tcp | head -1 | sed 's/.*://')"
  for _ in $(seq 1 30); do  # until its first scrape has written up{job="otel-collector"}
    curl -fsS --get --data-urlencode 'query=up{job="otel-collector"}' "http://127.0.0.1:${port}/api/v1/query" 2>/dev/null \
      | grep -q '"value"' && return 0
    sleep 1
  done
  return 1
}

mismatches=0
scenario() {  # scenario <name> <scrape target> <want: a value, or "fail">
  local out status got verdict=ok port=""
  if ! start "$2"; then
    got="no Prometheus"
  else
    out="$(PATH="${work}/bin:${PATH}" PROM_PORT="${port}" bash -o pipefail -c "${function_text}
prometheus_value" 2>/dev/null)"; status=$?
    if [ "${status}" -eq 0 ]; then got="${out}"; else got=fail; fi
  fi
  [ "${got}" = "$3" ] || { verdict=MISMATCH; mismatches=$((mismatches + 1)); }
  printf '%-9s %-44s %s (want %s)\n' "${verdict}" "$1" "${got}" "$3"
}
scenario "collector scraped, no span yet (up 1)"   127.0.0.1:9090 0
scenario "collector scrape failing (up 0)"         127.0.0.1:1    fail
echo "mismatches: ${mismatches}"; exit "${mismatches}"
