#!/usr/bin/env bash
# Usage: tests/spikes/r1-6_envoy_attempt_spans.sh   (from the demo directory, against the running lab)
# Spike for R1.6 (#109): when Envoy retries an upstream request, is each attempt its own span?
# A throwaway Envoy (the lab's image) joins only fabric_net-otelsend and exports its spans through
# the lab's Envoy (otlp.mesh) like any sender. Its one route goes to a closed port with
# retry_on: connect-failure and 3 retries, so one request makes 4 attempts. It runs twice, with
# spawn_upstream_span false and then true, and Tempo is asked how many spans each trace holds.
# Changes nothing in the running lab; the throwaway container is removed on any exit.
set -euo pipefail
readonly name="spike-r1-6-envoy"
readonly out="output/spike-r1-6-envoy-attempt-spans.txt"
# A service name of this run's own, so Tempo cannot answer with an earlier run's traces.
run_id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
image="$(podman inspect fabric-envoy-1 --format '{{.ImageName}}')"
# Under the demo, not $TMPDIR: the Podman machine mounts only the home directory.
work="$(mktemp -d "${PWD}/.spike-r1-6.XXXXXX")"
trap 'podman rm -f "${name}" >/dev/null 2>&1 || true; rm -rf "${work}"' EXIT

config() {  # config <true|false>: the throwaway Envoy's whole configuration
  cat <<EOF
static_resources:
  listeners:
  - name: spike
    address: {socket_address: {address: 0.0.0.0, port_value: 10000}}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: spike
          tracing:
            spawn_upstream_span: $1
            provider:
              name: envoy.tracers.opentelemetry
              typed_config:
                "@type": type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig
                service_name: ${name}-${run_id}-spawn-$1
                http_service:
                  http_uri: {uri: "http://otlp.mesh:18080/v1/traces", cluster: otlp, timeout: 2s}
          route_config:
            virtual_hosts:
            - name: closed
              domains: ["*"]
              routes:
              - match: {prefix: /}
                route:
                  cluster: closed_port
                  retry_policy: {retry_on: connect-failure, num_retries: 3}
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: closed_port
    type: STATIC
    connect_timeout: 1s
    load_assignment:
      cluster_name: closed_port
      endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 9}}}}]}]
  - name: otlp
    type: STRICT_DNS
    connect_timeout: 2s
    load_assignment:
      cluster_name: otlp
      endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: otlp.mesh, port_value: 18080}}}}]}]
EOF
}

tempo() {  # tempo <path>: a GET on Tempo through the lab's Envoy, from Grafana (which holds tempo.mesh)
  podman exec fabric-grafana-1 curl -s "http://tempo.mesh:18080$1"
}

run() {  # run <true|false> <want>: one request through a fresh throwaway Envoy; checks its spans
  config "$1" > "${work}/envoy.yaml"
  podman rm -f "${name}" >/dev/null 2>&1 || true
  # As the lab runs Envoy: its own entrypoint and an unprivileged user (the image's entrypoint
  # tries to chown /dev/stdout, which rootless Podman refuses).
  podman run -d --name "${name}" --network fabric_net-otelsend -p 127.0.0.1::10000 \
    --user 10008:10008 --entrypoint envoy -v "${work}/envoy.yaml:/etc/envoy/envoy.yaml:ro,Z" "${image}" \
    -c /etc/envoy/envoy.yaml --log-level warn --disable-hot-restart >/dev/null
  local port code waited=0
  port="$(podman port "${name}" 10000/tcp | sed 's/.*://')"
  until curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "${waited}" -ge 30 ]; then echo "  Envoy did not answer in 30 s:"; podman logs --tail 20 "${name}"; return 1; fi
    sleep 1
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/spike")"
  echo "spawn_upstream_span=$1: request answered ${code}"
  # The readiness probe above was traced too; the probe's request has path /, this one /spike.
  # Envoy's OpenTelemetry tracer sends its spans every 5 s (tracer.cc:203-205,
  # tracing.opentelemetry.flush_interval_ms) and a removed container sends nothing: wait it out.
  sleep 7
  podman rm -f "${name}" >/dev/null
  local service="${name}-${run_id}-spawn-$1" ids id tries=0 got
  until ids="$(tempo "/api/search?tags=service.name%3D${service}&limit=20" |
    python3 -c 'import json,sys; print(" ".join(t["traceID"] for t in json.load(sys.stdin).get("traces", [])))')" &&
    [ -n "${ids}" ]; do
    tries=$((tries + 1)); [ "${tries}" -lt 30 ] || { echo "  no trace for ${service} in Tempo after 60 s"; return 1; }
    sleep 2
  done
  for id in ${ids}; do
    tempo "/api/v2/traces/${id}" | python3 -c '
import json, sys
spans = [s for b in json.load(sys.stdin)["trace"]["resourceSpans"] for ss in b["scopeSpans"] for s in ss["spans"]]
tags = lambda s: {a["key"]: next(iter(a["value"].values())) for a in s.get("attributes", [])}
paths = {tags(s).get("http.url", "") for s in spans}
if not any(p.endswith("/spike") for p in paths):
    sys.exit(0)  # the readiness probe trace
print(f"  trace {sys.argv[1]}: {len(spans)} spans")
for s in sorted(spans, key=lambda s: int(s["startTimeUnixNano"])):
    t, name = tags(s), s["name"]
    retry, status = t.get("retry.count", "-"), t.get("http.status_code", "-")
    print(f"    {name:<36} retry.count={retry}  status={status}")
egress = sorted(tags(s).get("retry.count", "0") for s in spans if s["name"].startswith("router "))
counts = ",".join(egress) or "-"
print(f"  summary spans={len(spans)} attempts={len(egress)} retry.counts={counts}")
' "${id}"
  done | tee "${work}/trace.txt"
  got="$(grep -o 'spans=.*' "${work}/trace.txt" || true)"
  if [ "${got}" = "$2" ]; then echo "  verdict as expected: ${got}"; else echo "  verdict UNEXPECTED: got '${got}', want '$2'"; return 1; fi
}

{
  echo "Envoy image: ${image}"
  # Expected from Envoy v1.36.11's source (#99): one span for the whole request by default; with
  # spawn_upstream_span, one egress span per attempt, the retries tagged 1 to 3.
  run false "spans=1 attempts=0 retry.counts=-"
  run true "spans=5 attempts=4 retry.counts=0,1,2,3"
} | tee "${out}"
