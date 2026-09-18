#!/usr/bin/env bash
# test: `eg-up.sh eg2` must COPY eg1's root Secret and never apply clusters/eg/eg-root-ca.yaml on kind-eg2;
# `eg-up.sh eg2 eg1` must process eg1 first. Runs the script against fake kind/kubectl/helm/docker.
# usage: bash tests/eg-up-root-home.sh scripts/eg-up.sh   (exit 0 = test passes)
set -uo pipefail
UP=${1:?eg-up.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$(cd "$(dirname "$UP")/.." && pwd)
mkdir -p "$T/bin" "$T/repo/scripts/bootstrap" "$T/repo/clusters/eg" "$T/repo/demos/50-eg-clusters/output"
cp "$UP" "$T/repo/scripts/eg-up.sh"; cp "$R/scripts/record.sh" "$R/scripts/eg-net.sh" "$T/repo/scripts/"
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/"; cp "$R/clusters/eg/"*.yaml "$T/repo/clusters/eg/"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/k" -out "$T/c" -subj /CN=eg-root-ca -days 30 >/dev/null 2>&1
CRT=$(base64 < "$T/c" | tr -d '\n')
cat > "$T/bin/stub" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$STUB_LOG"
case "\$(basename "\$0") \$*" in
  "docker network inspect kind-eg --format "*"ip-range="*) echo 'subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1' ;;
  "docker network inspect kind-eg"*) echo '172.19.0.0/16 ' ;;
  "docker "*) echo 65535 ;;
  "kind get clusters") printf 'eg1\neg2\n' ;;
  "helm upgrade --install eg-crds"*) echo 'Error: create: failed to create: Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long: may not be more than 1048576 bytes'; exit 1 ;;
  "helm "*) echo ok ;;
  *"get nodes -o json") echo '{"items":[{"metadata":{"name":"n"},"status":{"addresses":[{"type":"InternalIP","address":"172.19.0.2"}]}}]}' ;;
  *"get crd -o name") for n in a b c d e f g h i j; do echo "customresourcedefinition.apiextensions.k8s.io/\$n.gateway.networking.k8s.io"; done; for n in a b c d e f g h; do echo "customresourcedefinition.apiextensions.k8s.io/\$n.gateway.envoyproxy.io"; done ;;
  *"/channel}"*) printf standard ;;
  *"/bundle-version}"*) printf v1.6.2 ;;
  *"get cm kube-proxy -o yaml"*) printf '    mode: iptables\n' ;;
  *"get secret eg-root-ca -o name"*) echo secret/eg-root-ca ;;
  *"get secret eg-root-ca -o json") printf '{"type":"kubernetes.io/tls","metadata":{"name":"eg-root-ca"},"data":{"tls.crt":"$CRT","tls.key":"x"}}\n' ;;
  *"tls\\.crt}"*) printf '%s' '$CRT' ;;
  *"-o jsonpath"*) printf True ;;
  "kubectl "*) echo ok ;;
esac
STUB
chmod +x "$T/bin/stub"; for t in kind kubectl helm docker; do ln -s stub "$T/bin/$t"; done
run() { : > "$T/log"; (cd "$T/repo" && STUB_LOG="$T/log" PATH="$T/bin:/usr/bin:/bin" bash scripts/eg-up.sh "$@" >"$T/out" 2>&1); echo $?; }
rc=$(run eg2)
if grep -q 'kubectl --context kind-eg2 apply -f clusters/eg/eg-root-ca.yaml' "$T/log"; then echo "TEST FAIL: eg-up.sh eg2 minted a root on eg2 (rc=$rc)"; exit 1; fi
grep -q 'kubectl --context kind-eg1 -n cert-manager get secret eg-root-ca -o json' "$T/log" || { echo "TEST FAIL: eg-up.sh eg2 did not copy eg1's Secret (rc=$rc)"; exit 1; }
rc=$(run eg2 eg1)
first_ctx=$(grep -m1 -oE 'kubectl --context kind-eg[12] wait --for=condition=Ready nodes' "$T/log" | grep -oE 'kind-eg[12]')
[ "$first_ctx" = kind-eg1 ] || { echo "TEST FAIL: 'eg-up.sh eg2 eg1' processed $first_ctx first"; exit 1; }
# F5 — the vendor pipe is the method; a Helm release of the CRD chart is not attempted
if grep -q 'helm upgrade --install eg-crds' "$T/log"; then echo "TEST FAIL: doomed helm upgrade --install eg-crds was invoked"; exit 1; fi
grep -q 'helm template eg-crds' "$T/log" || { echo "TEST FAIL: helm template eg-crds was not invoked"; exit 1; }
echo "TEST PASS: eg2 copies eg1's root; eg1 is always first; no doomed CRD release"; exit 0
