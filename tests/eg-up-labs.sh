#!/usr/bin/env bash
# test: eg-up.sh treats the two-cluster lab (eg1/eg2) and the one-cluster lab
# (eg-poc1) as separate labs. PATH-stub harness in the style of
# tests/eg-up-root-home.sh.
#   (a) `eg-up.sh eg-poc1` mints the root on eg-poc1 and exports
#       .tmp/eg-poc1-root-ca.crt, never touches kind-eg1
#   (b) `eg-up.sh eg1 eg-poc1` exits 2 before doing anything
#   (c) `eg-up.sh eg2` alone still dies "run eg1 first" when eg1's Secret is absent
# usage: bash tests/eg-up-labs.sh scripts/eg-up.sh   (exit 0 = test passes)
set -uo pipefail
UP=${1:?eg-up.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$(cd "$(dirname "$UP")/.." && pwd)
mkdir -p "$T/bin" "$T/repo/scripts/bootstrap" "$T/repo/clusters/eg" \
  "$T/repo/demos/50-eg-clusters/output" "$T/repo/demos/54-eg-poc1-kube-vip/output"
cp "$UP" "$T/repo/scripts/eg-up.sh"
cp "$R/scripts/record.sh" "$R/scripts/eg-net.sh" "$T/repo/scripts/"
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/"
cp "$R/clusters/eg/"*.yaml "$T/repo/clusters/eg/"
cp "$R/clusters/eg-poc1.yaml" "$T/repo/clusters/"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$T/k" -out "$T/c" -subj /CN=eg-root-ca -days 30 >/dev/null 2>&1
CRT=$(base64 < "$T/c" | tr -d '\n')

# STUB_SECRET=1 → get secret -o name succeeds (eg1 has the root).
# STUB_SECRET=0 → get secret -o name fails (eg1's Secret is absent).
cat > "$T/bin/stub" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$STUB_LOG"
case "\$(basename "\$0") \$*" in
  "docker network inspect kind-eg --format "*"ip-range="*) echo 'subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1' ;;
  "docker network inspect kind-eg"*) echo '172.19.0.0/16 ' ;;
  "docker "*) echo 65535 ;;
  "kind get clusters") printf 'eg1\neg2\neg-poc1\n' ;;
  "helm upgrade --install eg-crds"*) echo 'Error: create: failed to create: Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long: may not be more than 1048576 bytes'; exit 1 ;;
  "helm "*) echo ok ;;
  *"get nodes -o json") echo '{"items":[{"metadata":{"name":"n"},"status":{"addresses":[{"type":"InternalIP","address":"172.19.0.2"}]}}]}' ;;
  *"get crd -o name") for n in a b c d e f g h i j; do echo "customresourcedefinition.apiextensions.k8s.io/\$n.gateway.networking.k8s.io"; done; for n in a b c d e f g h; do echo "customresourcedefinition.apiextensions.k8s.io/\$n.gateway.envoyproxy.io"; done ;;
  *"/channel}"*) printf standard ;;
  *"/bundle-version}"*) printf v1.6.2 ;;
  *"get cm kube-proxy -o yaml"*) printf '    mode: iptables\n' ;;
  *"get secret eg-root-ca -o name"*)
    if [ "\${STUB_SECRET:-1}" = 1 ]; then echo secret/eg-root-ca
    else echo 'Error from server (NotFound): secrets "eg-root-ca" not found' >&2; exit 1
    fi ;;
  *"get secret eg-root-ca -o json") printf '{"type":"kubernetes.io/tls","metadata":{"name":"eg-root-ca"},"data":{"tls.crt":"$CRT","tls.key":"x"}}\n' ;;
  *"tls\\.crt}"*) printf '%s' '$CRT' ;;
  *"-o jsonpath"*) printf True ;;
  "kubectl "*) echo ok ;;
esac
STUB
chmod +x "$T/bin/stub"
for t in kind kubectl helm docker; do ln -s stub "$T/bin/$t"; done

run() {
  : > "$T/log"
  (cd "$T/repo" && STUB_LOG="$T/log" STUB_SECRET="${STUB_SECRET:-1}" \
    PATH="$T/bin:/usr/bin:/bin" bash scripts/eg-up.sh "$@" >"$T/out" 2>&1)
  echo $?
}

# (a) eg-poc1 mints its own root and exports .tmp/eg-poc1-root-ca.crt; never kind-eg1
STUB_SECRET=1
rc=$(run eg-poc1)
if grep -q 'kind-eg1' "$T/log"; then
  echo "TEST FAIL: eg-up.sh eg-poc1 touched kind-eg1 (rc=$rc)"
  exit 1
fi
grep -q 'kubectl --context kind-eg-poc1 apply -f clusters/eg/eg-root-ca.yaml' "$T/log" \
  || { echo "TEST FAIL: eg-up.sh eg-poc1 did not mint the root on eg-poc1 (rc=$rc)"; exit 1; }
[ -f "$T/repo/.tmp/eg-poc1-root-ca.crt" ] \
  || { echo "TEST FAIL: .tmp/eg-poc1-root-ca.crt was not written (rc=$rc)"; exit 1; }
grep -q 'eg-poc1-root-ca.crt' "$T/repo/demos/54-eg-poc1-kube-vip/output/transcript.txt" \
  || { echo "TEST FAIL: transcript does not record the eg-poc1 root export (rc=$rc)"; exit 1; }
if grep -qE '> \.tmp/eg-root-ca\.crt' "$T/repo/demos/54-eg-poc1-kube-vip/output/transcript.txt" \
   || grep -qE '> \.tmp/eg-root-ca\.crt' "$T/log"; then
  echo "TEST FAIL: eg-up.sh eg-poc1 wrote the two-cluster export path .tmp/eg-root-ca.crt"
  exit 1
fi

# (b) mixing labs exits 2 before any stub is invoked
: > "$T/log"
(cd "$T/repo" && STUB_LOG="$T/log" PATH="$T/bin:/usr/bin:/bin" \
  bash scripts/eg-up.sh eg1 eg-poc1 >"$T/out" 2>&1)
rc=$?
[ "$rc" -eq 2 ] || { echo "TEST FAIL: eg-up.sh eg1 eg-poc1 exit $rc, want 2"; exit 1; }
if [ -s "$T/log" ]; then
  echo "TEST FAIL: eg-up.sh eg1 eg-poc1 invoked a stub before exiting:"
  cat "$T/log"
  exit 1
fi

# (c) eg2 alone still dies "run eg1 first" when eg1's Secret is absent
STUB_SECRET=0
rc=$(run eg2)
if [ "$rc" -eq 0 ]; then
  echo "TEST FAIL: eg-up.sh eg2 succeeded when eg1's Secret was absent"
  exit 1
fi
grep -q 'run scripts/eg-up.sh eg1 first' "$T/out" \
  || { echo "TEST FAIL: eg-up.sh eg2 did not die 'run eg1 first' (rc=$rc)"; echo "--- out ---"; cat "$T/out"; exit 1; }

echo "TEST PASS: eg-poc1 mints its own root; mix exits 2; eg2 still requires eg1 first"
exit 0
