#!/usr/bin/env bash
# check.sh [count] — drive the petclinic API through the Gateway: owners, one owner's pets, vets, a visit, and record
# which backend answered each. Usage: demos/20-springboot/check.sh 5
set -uo pipefail; N="${1:-5}"; cd "$(dirname "$0")/../.."
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
c() { curl -s --cacert "${ROOT_CA:-docs/root-ca.crt}" --resolve petclinic.poc.local:443:$GW -m 15 "$@"; }   # ROOT_CA: another lab's root (the CI lab exports its own)
printf "  %-42s %s\n" "GET /api/customer/owners" "$(c -o /dev/null -w '%{http_code} in %{time_total}s' https://petclinic.poc.local/api/customer/owners)"
printf "  %-42s %s\n" "GET /api/customer/owners/1" "$(c https://petclinic.poc.local/api/customer/owners/1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["firstName"], d["lastName"], "pets:", [p["name"] for p in d.get("pets",[])])' 2>/dev/null || echo failed)"
printf "  %-42s %s\n" "GET /api/vet/vets" "$(c https://petclinic.poc.local/api/vet/vets | python3 -c 'import json,sys; print(len(json.load(sys.stdin)), "vets")' 2>/dev/null || echo failed)"
printf "  %-42s %s\n" "GET /api/visit/owners/1/pets/1/visits" "$(c https://petclinic.poc.local/api/visit/owners/1/pets/1/visits | python3 -c 'import json,sys; print(len(json.load(sys.stdin)), "visits")' 2>/dev/null || echo failed)"
printf "  %-42s %s\n" "GET /api/gateway/owners/1 (gateway fan-out)" "$(c -o /dev/null -w '%{http_code} in %{time_total}s' https://petclinic.poc.local/api/gateway/owners/1)"
printf "  %-42s " "POST /api/visit/owners/1/pets/1/visits"; c -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -d '{"date":"2026-09-12","description":"cilium-kind-poc check"}' https://petclinic.poc.local/api/visit/owners/1/pets/1/visits
echo "  ${N} × GET /api/gateway/owners/1:"; for i in $(seq 1 "$N"); do c -o /dev/null -w '    %{http_code} %{time_total}s\n' https://petclinic.poc.local/api/gateway/owners/1; done
