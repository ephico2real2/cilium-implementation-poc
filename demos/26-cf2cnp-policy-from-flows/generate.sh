#!/usr/bin/env bash
# generate.sh <flow.json> [out.yaml] — the API path: POST the flow to cf2cnp and keep the YAML. With JSON=1, ask for the
# JSON answer instead (the download URL keyed by the flow's UUID, cached 10 minutes) — what Grafana's action receives.
set -uo pipefail; cd "$(dirname "$0")/../.."; F="${1:?flow.json}"; OUT="${2:-}"
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
if [ "${JSON:-0}" = 1 ]; then curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW -X POST https://cf2cnp.poc.local/generate -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary @"$F"; echo; exit; fi
if [ -n "$OUT" ]; then curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW -X POST https://cf2cnp.poc.local/generate -H 'Content-Type: application/json' --data-binary @"$F" -o "$OUT" -w "http=%{http_code} → $OUT\n"; else curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW -X POST https://cf2cnp.poc.local/generate -H 'Content-Type: application/json' --data-binary @"$F"; fi
