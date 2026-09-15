#!/usr/bin/env bash
# cleanup.sh — remove the Bundle and trust-manager from both clusters (the ConfigMaps go with the Bundle) and the root from
# THIS host's trust store. The issuer and its Secret stay: they are demo 08's, and the mesh, the relay and the wildcard
# are signed by them.
set -uo pipefail; cd "$(dirname "$0")/../.."
for c in kind-poc1 kind-poc2; do
  kubectl --context "$c" get nodes >/dev/null 2>&1 || continue
  kubectl --context "$c" delete bundle enterprise-root --ignore-not-found
  helm uninstall trust-manager -n cert-manager --kube-context "$c" 2>/dev/null || true
done
case "$(uname -s)" in
  Linux)  sudo rm -f /usr/local/share/ca-certificates/cilium-lab-enterprise-root.crt && sudo update-ca-certificates 2>&1 | grep -E 'removed|done' ;;
  Darwin) [ -s .tmp/root-ca.crt ] && sudo security remove-trusted-cert -d .tmp/root-ca.crt && echo "removed from the System keychain" ;;
esac
echo "trust-manager and the Bundle removed; the host no longer trusts the root; demo 08's issuer untouched"
