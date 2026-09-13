#!/usr/bin/env bash
# generate.sh <flow.json> [out.yaml] — the API path: POST the flow(s) to cf2cnp and keep the YAML. With JSON=1, ask for the
# JSON answer instead (download_url keyed by the flow's UUID, the filename, the counts and the YAML — what Grafana receives).
# With QUERY=<k=v&k=v>, the parameters go on the URL (demo 30: QUERY=l7=true; demo 31: QUERY=dnsVisibility=true; ?name=, ?exclude=).
# An HTTP error is an error: curl --fail-with-body exits 22 and prints cf2cnp's message, and the output file is written
# only from a 2xx answer (the first version wrote "Request body is empty" INTO the .yaml files and exited 0 — review finding).
set -uo pipefail; cd "$(dirname "$0")/../.."; F="${1:?flow.json}"; OUT="${2:-}"
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
POST=(curl --silent --show-error --fail-with-body --cacert docs/root-ca.crt --resolve "cf2cnp.poc.local:443:$GW" -X POST "https://cf2cnp.poc.local/generate${QUERY:+?$QUERY}" -H 'Content-Type: application/json' --data-binary "@$F")
if [ "${JSON:-0}" = 1 ]; then "${POST[@]}" -H 'Accept: application/json' || { RC=$?; echo >&2; exit $RC; }; echo; exit 0; fi
[ -n "$OUT" ] || { "${POST[@]}"; exit $?; }
[ -d "$(dirname -- "$OUT")" ] || { echo "generate.sh: directory $(dirname -- "$OUT") does not exist" >&2; exit 1; }
TMP=$(mktemp "${OUT}.XXXXXX") || exit 1; trap 'rm -f "$TMP"' EXIT
if CODE=$("${POST[@]}" -o "$TMP" -w '%{http_code}'); then mv "$TMP" "$OUT"; trap - EXIT; echo "http=$CODE → $OUT"
else RC=$?; echo "generate.sh: cf2cnp answered http=$CODE: $(cat "$TMP")" >&2; exit $RC; fi
