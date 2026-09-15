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
#   scripts/lab-trust.sh kyverno <ctx>…       Kyverno (the version below) and the MutatingPolicy mount-enterprise-root: every pod labelled
#                                             trust.poc.local/root=enterprise gets the ConfigMap mounted and SSL_CERT_FILE set in every
#                                             container at admission — the mount without asking (demos/36-trust-everywhere/40-kyverno-mutatingpolicy.yaml)
#   scripts/lab-trust.sh labelled-check <ctx> <ns> <pod> <gateway-ip> <host>
#                                             a labelled pod declared without any mount: the mutation in its spec, then a curl with NO flag (SSL_CERT_FILE)
#
# The operator's rule (2026-09-15): the root is added to the MacBook's trust store and to the Ubuntu host in CI in the same
# exercise that copies it between the clusters, and mounted into any pod that calls a Gateway URL — not carried as a
# --cacert flag in every script. `install` and `bundle` are what lab-up.sh runs (LAB_TRUST_ROOT=1 for the host part).
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; ROOT=.tmp/root-ca.crt; STORE_NAME=cilium-lab-enterprise-root
TRUST_MANAGER_VERSION="${TRUST_MANAGER_VERSION:-v0.25.0}"   # jetstack/trust-manager; needs cert-manager for its own webhook certificate
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.9.1}"      # kyverno/kyverno chart 3.9.1 = Kyverno v1.19.1 (released 2026-09-10, the latest on 2026-09-15)
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
    # `helm --wait` returns when the Deployment is Ready, not when its validating webhook is reachable from the API server:
    # the first apply on poc2 met `failed calling webhook "trust.cert-manager.io" … connect: no route to host` (run
    # 34936560683, gotcha #107) — the Bundle is applied until the webhook answers, up to a minute
    local _a out; for _a in $(seq 1 12); do
      out=$(kubectl --context "$ctx" apply -f demos/36-trust-everywhere/20-bundle.yaml 2>&1) && break
      case "$out" in *"failed calling webhook"*) sleep 5;; *) echo "$out" >&2; die "Bundle apply failed on $ctx";; esac
    done
    [ "$_a" -lt 12 ] || { echo "$out" >&2; die "trust-manager's webhook on $ctx never answered in 60 s"; }
    [ "$_a" -gt 1 ] && echo "  (the Bundle applied at attempt $_a: trust-manager's webhook was not reachable yet)"
    local _i; for _i in $(seq 1 30); do [ "$(kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null)" = True ] && break; sleep 2; done
    [ "$(kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null)" = True ] || { kubectl --context "$ctx" get bundle enterprise-root -o jsonpath='{.status}'; echo; die "Bundle enterprise-root is not Synced on $ctx"; }
    n=$(kubectl --context "$ctx" get cm -A --field-selector metadata.name=enterprise-root --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "$ctx: trust-manager $TRUST_MANAGER_VERSION, Bundle enterprise-root Synced → ConfigMap enterprise-root/ca.crt in $n namespaces: $(kubectl --context "$ctx" get cm -A --field-selector metadata.name=enterprise-root -o jsonpath='{.items[0].data.ca\.crt}' | grep -c 'BEGIN CERTIFICATE') certificates (the public roots + ours, $(kubectl --context "$ctx" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)…)"
  done
}
pod_check() { # <ctx> <ns> <pod> [container] <gateway-ip> <host> — inside a pod that mounts the bundle at /etc/enterprise-root
  local ctx="$1" ns="$2" pod="$3" c=() gw host
  if [ $# -ge 6 ]; then c=(-c "$4"); gw="$5"; host="$6"; else gw="$4"; host="$5"; fi
  local with without
  with=$(kubectl --context "$ctx" -n "$ns" exec "$pod" "${c[@]}" -- sh -c "curl -s -o /dev/null -m 8 --cacert /etc/enterprise-root/ca.crt --resolve $host:443:$gw -w '%{http_code}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  without=$(kubectl --context "$ctx" -n "$ns" exec "$pod" "${c[@]}" -- sh -c "curl -s -o /dev/null -m 8 --resolve $host:443:$gw -w '%{http_code}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  local viaenv
  viaenv=$(kubectl --context "$ctx" -n "$ns" exec "$pod" "${c[@]}" -- sh -c "SSL_CERT_FILE=/etc/enterprise-root/ca.crt curl -s -o /dev/null -m 8 --resolve $host:443:$gw -w '%{http_code}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  printf '  %s/%s → https://%s  --cacert the mounted bundle: %s   SSL_CERT_FILE=the bundle, no flag: %s   with nothing: %s\n' "$ns" "$pod" "$host" "$with" "$viaenv" "$without"
  case "$with" in 200*|301*|302*) ;; *) die "the pod's curl with the mounted root did not get an answer ($with)";; esac
  case "$viaenv" in 200*|301*|302*) echo "  ✓ SSL_CERT_FILE alone is enough for this image's curl (no CURL_CA_BUNDLE pinned in it)";; *) echo "  ✗ SSL_CERT_FILE alone did not verify ($viaenv): this image pins another variable (curl reads CURL_CA_BUNDLE first)";; esac
  case "$without" in *"rc=60"*|*"rc=77"*|*"rc=35"*) echo "  ✓ without the root the pod's curl is refused (curl exit ${without##*rc=}: the peer certificate cannot be authenticated) — the mount is what makes the call trusted";;
    *) die "without the root the pod's curl should have been refused, got '$without' — the image trusts something it should not";; esac
}
kyverno() { # <ctx>… — Kyverno and the MutatingPolicy on each cluster; ready when a policy object reports it
  local ctx st _i; for ctx in "$@"; do
    helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
    helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" --namespace kyverno --create-namespace --kube-context "$ctx" --wait --timeout 5m >/dev/null
    local _a out; for _a in $(seq 1 12); do   # the same webhook window as trust-manager's (gotcha #107)
      out=$(kubectl --context "$ctx" apply -f demos/36-trust-everywhere/40-kyverno-mutatingpolicy.yaml 2>&1) && break
      case "$out" in *"failed calling webhook"*) sleep 5;; *) echo "$out" >&2; die "MutatingPolicy apply failed on $ctx";; esac
    done
    [ "$_a" -lt 12 ] || { echo "$out" >&2; die "Kyverno's webhook on $ctx never answered in 60 s"; }
    # the policy's Ready condition (the CEL policy types report status.conditionStatus, the classic ones status.conditions)
    for _i in $(seq 1 30); do
      st=$(kubectl --context "$ctx" get mutatingpolicy mount-enterprise-root -o jsonpath='{.status.conditionStatus.ready}{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      case "$st" in *true*|*True*) break;; esac; sleep 2
    done
    echo "$ctx: Kyverno $(helm list -n kyverno --kube-context "$ctx" -o json | jq -r '.[0].app_version') (chart $KYVERNO_CHART_VERSION), MutatingPolicy mount-enterprise-root ready=${st:-unknown after 60 s}"
  done
}
labelled_check() { # <ctx> <ns> <pod> <gateway-ip> <host> — what admission added, then the curl a process makes with no flag at all
  local ctx="$1" ns="$2" pod="$3" gw="$4" host="$5" spec out
  spec=$(kubectl --context "$ctx" -n "$ns" get pod "$pod" -o jsonpath='volumes={.spec.volumes[*].name} mounts={.spec.containers[*].volumeMounts[*].mountPath} env={.spec.containers[*].env[*].name}')
  echo "  $ns/$pod as admitted: $spec"
  case "$spec" in *enterprise-root*/etc/enterprise-root*SSL_CERT_FILE*) echo "  ✓ the mutation is in the spec: the volume, the mount, SSL_CERT_FILE — the manifest declared none of them";;
    *) die "the labelled pod was not mutated (is Kyverno's policy ready? scripts/lab-trust.sh kyverno $ctx)";; esac
  out=$(kubectl --context "$ctx" -n "$ns" exec "$pod" -- sh -c "curl -s -o /dev/null -m 8 --resolve $host:443:$gw -w '%{http_code} %{ssl_verify_result}' https://$host/ 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tr -d '\n')
  echo "  curl https://$host/ from the pod, no --cacert, no flag: http ${out%% *}, ssl_verify_result $(echo "$out" | awk '{print $2}'), ${out##* }"
  case "$out" in 200\ 0*|301\ 0*|302\ 0*) echo "  ✓ verified through SSL_CERT_FILE alone";; *) die "the labelled pod's flagless curl did not verify ($out)";; esac
  kubectl --context "$ctx" -n "$ns" get events --field-selector involvedObject.name="$pod",reason=PolicyApplied -o jsonpath='{range .items[*]}  event: {.reason} — {.message}{"\n"}{end}' 2>/dev/null | head -2 || true
}

[ $# -ge 1 ] || { sed -n 2,27p "$0"; exit 2; }
cmd="$1"; shift
case "$cmd" in
  export) export_root "$@";;
  install) install_root "$@";;
  verify) verify_root "$@";;
  prove) prove "$@";;
  bundle) bundle "$@";;
  pod-check) pod_check "$@";;
  kyverno) kyverno "$@";;
  labelled-check) labelled_check "$@";;
  *) die "unknown command $cmd";;
esac
