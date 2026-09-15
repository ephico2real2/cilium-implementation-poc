#!/usr/bin/env bash
# lab-trust.sh — one root, everywhere (demo 36). The enterprise root is cert-manager's ClusterIssuer/ca-issuer's CA: the
# Secret clustermesh-root-ca (demo 08, copied to every cluster in the mesh exercise), the CA that signs demo 09's
# wildcard *.poc.local, the mesh's certificates on route A and the relay's mTLS certificates. A client must verify
# against that ROOT, not against any of the leaf certificates — so the root goes into every place a client lives:
#
#   scripts/lab-trust.sh export  [ctx]        the root's certificate (only tls.crt, never the key) → .tmp/root-ca.crt
#   scripts/lab-trust.sh install [ctx]        … and into THIS host's trust store, the OS's way (sudo):
#                                             Ubuntu/Debian: /usr/local/share/ca-certificates + update-ca-certificates
#                                             macOS: security add-trusted-cert -d -r trustRoot -k the System keychain (demo 09)
#   scripts/lab-trust.sh verify  [ctx]        the host's store verifies the root (openssl verify against the OS store / security verify-cert)
#   scripts/lab-trust.sh prove   <gateway-ip> a curl BY NAME to the wildcard listener with NO --cacert: ssl_verify_result must be 0
#   scripts/lab-trust.sh bundle  <ctx>…       trust-manager on the cluster(s) and the Bundle `enterprise-root`: the root as a
#                                             ConfigMap (key ca.crt) in EVERY namespace, for pods to mount (demos/36-trust-everywhere/20-bundle.yaml)
#   scripts/lab-trust.sh pod-check <ctx> <ns> <pod> [container] <gateway-ip> <host>
#                                             from inside a pod with the bundle mounted: curl with the mounted root (200) and without (refused)
#
# The operator's rule (2026-09-15): the root is added to the MacBook's trust store and to the Ubuntu host in CI in the same
# exercise that copies it between the clusters, and mounted into any pod that calls a Gateway URL — not carried as a
# --cacert flag in every script. `install` and `bundle` are what lab-up.sh runs (LAB_TRUST_ROOT=1 for the host part).
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; ROOT=.tmp/root-ca.crt; STORE_NAME=cilium-lab-enterprise-root
TRUST_MANAGER_VERSION="${TRUST_MANAGER_VERSION:-v0.25.0}"   # jetstack/trust-manager; needs cert-manager for its own webhook certificate
die() { echo "::error::$1" >&2; exit 1; }
os() { uname -s; }

export_root() { # <ctx> — the certificate only; the key stays in the cluster (the Secret is the issuer's, not a bundle)
  local ctx="${1:-$CTX}"; mkdir -p .tmp
  kubectl --context "$ctx" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ROOT"
  [ -s "$ROOT" ] || die "no clustermesh-root-ca in $ctx's cert-manager namespace (route A: scripts/lab-up.sh with LAB_CERTMANAGER=1)"
  echo "the issuer's root from $ctx → $ROOT: $(openssl x509 -in "$ROOT" -noout -subject -fingerprint -sha256 | tr '\n' ' ' | cut -c1-150)"
}
install_root() { # the host's trust store, the OS's way; idempotent
  [ -s "$ROOT" ] || export_root "${1:-$CTX}"
  case "$(os)" in
    Linux)
      [ -d /usr/local/share/ca-certificates ] || die "no /usr/local/share/ca-certificates — not a Debian/Ubuntu trust store; add $ROOT your OS's way"
      sudo install -m 0644 "$ROOT" "/usr/local/share/ca-certificates/$STORE_NAME.crt"
      sudo update-ca-certificates 2>&1 | grep -E 'added|removed|done' | sed 's/^/  /' || true ;;
    Darwin)
      echo "  the System keychain: sudo asks for your password (demo 09's command)"
      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ROOT" ;;
    *) die "no trust-store recipe for $(os)" ;;
  esac
  verify_root
}
verify_root() { # the host's store, asked directly (no --cacert anywhere)
  [ -s "$ROOT" ] || export_root "${1:-$CTX}"
  case "$(os)" in
    Linux)  openssl verify -CApath /etc/ssl/certs "$ROOT" >/dev/null 2>&1 && echo "  the OS store trusts the root (openssl verify -CApath /etc/ssl/certs: OK)" || die "the OS store does not trust $ROOT (scripts/lab-trust.sh install)" ;;
    Darwin) security verify-cert -c "$ROOT" >/dev/null 2>&1 && echo "  the System keychain trusts the root (security verify-cert: OK)" || die "the keychain does not trust $ROOT (scripts/lab-trust.sh install)" ;;
  esac
}
prove() { # <gateway-ip> — the wildcard listener answers any *.poc.local name (404 from Envoy for one without a route); curl's
  # own verdict on the chain, ssl_verify_result, must be 0 — with no --cacert, the OS store is what verified it
  local gw="${1:?gateway ip}" v
  v=$(curl -s -o /dev/null --resolve "trust-check.poc.local:443:$gw" -w '%{http_code} %{ssl_verify_result}' https://trust-check.poc.local/ || true)
  [ "${v#* }" = 0 ] || die "the OS trust store does not verify the Gateway's certificate (curl by name, no --cacert: '${v:-no answer}')"
  echo "  curl by name with no --cacert → http ${v%% *}, ssl_verify_result ${v#* }: the OS store verified the wildcard's chain"
}
bundle() { # <ctx>… — trust-manager and the Bundle on each cluster: the root as ConfigMap enterprise-root/ca.crt in every namespace
  local ctx n; for ctx in "$@"; do
    helm upgrade --install trust-manager jetstack/trust-manager --version "$TRUST_MANAGER_VERSION" --namespace cert-manager --kube-context "$ctx" --wait --timeout 5m >/dev/null
    kubectl --context "$ctx" apply -f demos/36-trust-everywhere/20-bundle.yaml >/dev/null
    local _i; for _i in $(seq 1 30); do [ "$(kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null)" = True ] && break; sleep 2; done
    [ "$(kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null)" = True ] || { kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status}'; echo; die "Bundle enterprise-root is not Synced on $ctx"; }
    n=$(kubectl --context "$ctx" get cm -A --field-selector metadata.name=enterprise-root --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "$ctx: trust-manager $TRUST_MANAGER_VERSION, Bundle enterprise-root Synced → ConfigMap enterprise-root/ca.crt in $n namespaces ($(kubectl --context "$ctx" get cm -A --field-selector metadata.name=enterprise-root -o jsonpath='{.items[0].data.ca\.crt}' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)…)"
  done
}
pod_check() { # <ctx> <ns> <pod> [container] <gateway-ip> <host> — inside a pod that mounts the bundle at /etc/enterprise-root
  local ctx="$1" ns="$2" pod="$3" c=() gw host
  if [ $# -ge 6 ]; then c=(-c "$4"); gw="$5"; host="$6"; else gw="$4"; host="$5"; fi
  local with without
  with=$(kubectl --context "$ctx" -n "$ns" exec "$pod" "${c[@]}" -- sh -c "curl -s -o /dev/null -m 8 --cacert /etc/enterprise-root/ca.crt --resolve $host:443:$gw -w '%{http_code}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  without=$(kubectl --context "$ctx" -n "$ns" exec "$pod" "${c[@]}" -- sh -c "curl -s -o /dev/null -m 8 --resolve $host:443:$gw -w '%{http_code}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  printf '  %s/%s → https://%s  with the mounted root: %s   with nothing: %s\n' "$ns" "$pod" "$host" "$with" "$without"
  case "$with" in 200*|301*|302*) ;; *) die "the pod's curl with the mounted root did not get an answer ($with)";; esac
  case "$without" in *"rc=60"*|*"rc=77"*|*"rc=35"*) echo "  ✓ without the root the pod's curl is refused (curl exit ${without##*rc=}: the peer certificate cannot be authenticated) — the mount is what makes the call trusted";;
    *) die "without the root the pod's curl should have been refused, got '$without' — the image trusts something it should not";; esac
}

[ $# -ge 1 ] || { sed -n 2,22p "$0"; exit 2; }
cmd="$1"; shift
case "$cmd" in
  export) export_root "$@";;
  install) install_root "$@";;
  verify) verify_root "$@";;
  prove) prove "$@";;
  bundle) bundle "$@";;
  pod-check) pod_check "$@";;
  *) die "unknown command $cmd";;
esac
