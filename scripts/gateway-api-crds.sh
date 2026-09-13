#!/usr/bin/env bash
# gateway-api-crds.sh <kube-context> [<kube-context>...] — apply the vendored Gateway API CRDs (crds/gateway-api/<version>)
# to each cluster, server-side (the CRDs are too large for the client-side annotation), and wait until every one is
# Established. Offline: nothing is fetched. The version is the directory's; override with GATEWAY_API_VERSION.
#   scripts/gateway-api-crds.sh kind-poc1 kind-poc2
set -euo pipefail; cd "$(dirname "$0")/.."
V="${GATEWAY_API_VERSION:-v1.6.1}"; DIR="crds/gateway-api/$V"
[ $# -ge 1 ] || { echo "usage: $0 <kube-context> [<kube-context>...]"; exit 2; }
[ -d "$DIR" ] || { echo "no vendored CRDs for $V in $DIR (see crds/README.md)"; exit 1; }
for ctx in "$@"; do
  kubectl --context "$ctx" apply --server-side -f "$DIR" >/dev/null
  # the bundle version is an ANNOTATION on these CRDs, not a label, so the wait names them from the files
  names=$(grep -h '^  name: ' "$DIR"/*.yaml | awk '{print $2}' | tr '\n' ' ')
  # shellcheck disable=SC2086
  kubectl --context "$ctx" wait --for=condition=Established --timeout=2m crd $names >/dev/null
  echo "$ctx: Gateway API $V — $(echo $names | wc -w | tr -d ' ') CRDs established: $(echo $names | sed 's/\.gateway\.networking\.k8s\.io//g')"
done
