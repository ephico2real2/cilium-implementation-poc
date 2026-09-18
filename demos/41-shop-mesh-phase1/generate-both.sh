#!/usr/bin/env bash
# generate-both.sh — one cf2cnp /generate per cluster from policies/<cluster>/flows-audit.ndjson.
# cf2cnp runs on poc1 behind https://cf2cnp.poc.local (demo 25/26); this script always POSTs there.
# If poc2 produced no flows, copy poc1's YAML after reviewing cluster-specific selectors.
#
#   demos/41-shop-mesh-phase1/generate-both.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
HERE=demos/41-shop-mesh-phase1
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)
QUERY="${QUERY:-exclude=app.kubernetes.io%2Fname%3Dstranger}"
GEN=demos/26-cf2cnp-policy-from-flows/generate.sh

echo "== cf2cnp whereabouts (demo 25: the generator lives on poc1 behind routes-gw)"
kubectl --context kind-poc1 -n hubble-observer get deploy -l app.kubernetes.io/name=cf2cnp -o wide 2>/dev/null \
  || kubectl --context kind-poc1 -n hubble-observer get deploy 2>/dev/null | grep -i cf2cnp || true
echo "-- poc2 (expect none: cf2cnp is not installed there)"
kubectl --context kind-poc2 -n hubble-observer get deploy 2>/dev/null | grep -i cf2cnp \
  || echo "MEASURED GAP: no cf2cnp Deployment on poc2; both /generate calls go to poc1's Gateway."

review() {
  local f=$1
  echo "-- selectors in $f"
  python3 - "$f" <<'PY'
import sys
try:
    import yaml
except ImportError:
    yaml=None
path=sys.argv[1]
text=open(path).read()
cluster_hits=[ln for ln in text.splitlines() if "io.cilium.k8s.policy.cluster" in ln]
print("cluster-label lines:", len(cluster_hits))
for ln in cluster_hits:
    print(" ", ln.strip())
if yaml is None:
    sys.exit(0)
for d in yaml.safe_load_all(text):
    if not d: continue
    ns=d.get("metadata",{}).get("namespace","?")
    name=d.get("metadata",{}).get("name","?")
    desc=(d.get("spec") or {}).get("description","")
    print(f"  {ns:16} {name:20} {desc}")
PY
}

rc=0
poc1_yaml=""
for ctx in "${CTX_ARR[@]}"; do
  c=${ctx#kind-}
  flows="$HERE/policies/$c/flows-audit.ndjson"
  out="$HERE/policies/$c/cnp-shop-intent.yaml"
  mkdir -p "$(dirname "$out")"
  n=0
  [ -f "$flows" ] && n=$(wc -l < "$flows" | tr -d ' ')
  echo "== $c  flows=$n → $out"
  if [ "${n:-0}" -gt 0 ]; then
    if QUERY="$QUERY" "$GEN" "$flows" "$out"; then
      review "$out"
      [ "$c" = poc1 ] && poc1_yaml=$out
    else
      echo "generate-both.sh: cf2cnp /generate failed for $c" >&2
      rc=1
    fi
  else
    echo "MEASURED GAP: $c has no captured flows."
    if [ "$c" != poc1 ] && [ -n "$poc1_yaml" ] && [ -f "$poc1_yaml" ]; then
      echo "Copying $poc1_yaml → $out after reviewing cluster-specific selectors."
      review "$poc1_yaml"
      python3 - "$poc1_yaml" "$out" "$c" <<'PY'
import sys
src, dst, cluster = sys.argv[1], sys.argv[2], sys.argv[3]
text=open(src).read()
# A selector without io.cilium.k8s.policy.cluster matches the LOCAL cluster only (Cilium 1.19+).
# If poc1's YAML names cluster: poc1, rewrite that value to this cluster so local pods match.
# If it names none, the copy is valid as-is on the other cluster.
n=text.count("io.cilium.k8s.policy.cluster")
if n:
    text=text.replace("io.cilium.k8s.policy.cluster: poc1", f"io.cilium.k8s.policy.cluster: {cluster}")
    text=text.replace("io.cilium.k8s.policy.cluster: poc2", f"io.cilium.k8s.policy.cluster: {cluster}")
    print(f"rewrote {n} cluster-label occurrence(s) to {cluster}")
else:
    print("no cluster labels — copy is valid on the other cluster (local-only selectors, Cilium 1.19+)")
open(dst,"w").write(text)
PY
      review "$out"
    else
      echo "generate-both.sh: cannot copy poc1's policies for $c (poc1 YAML missing)" >&2
      rc=1
    fi
  fi
done
exit "$rc"
