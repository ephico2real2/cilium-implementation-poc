#!/usr/bin/env bash
# vip-takeover.sh — move the shop VIP's L2 announcement from one cluster to the other.
#
# Delete the policy from the OTHER cluster first, then apply it to the named one. Two announcers
# for one address is the failure the whole design avoids; a short gap is the price.
#
#   scripts/vip-takeover.sh poc1|poc2
#   scripts/vip-takeover.sh poc1|poc2 --force     # the OTHER cluster's API is down (DR): skip its delete
#   scripts/vip-takeover.sh --status
#
# Phase 0 proves this against a bare shop-vip-gw (no routes). Phase 5 (demo 45) uses it in DR — and in
# DR the other cluster's API server is exactly what is gone, so `--force` is the DR spelling: it
# WARNS that the other side could not be checked (its agents, if alive, may still announce) and
# applies anyway. Without --force the script fails closed: no delete, no apply.
# The DR spelling is `vip-takeover.sh poc2 --force`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$ROOT/cilium/l2-shop-vip-announce.yaml"
VIP="172.18.255.16"
LEASE_GREP='cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw'

ctx_of() {
  case "$1" in
    poc1|kind-poc1) echo kind-poc1 ;;
    poc2|kind-poc2) echo kind-poc2 ;;
    *) echo "usage: $0 poc1|poc2 | --status" >&2; exit 2 ;;
  esac
}

print_arp() {
  if command -v arp >/dev/null 2>&1; then
    echo "== arp -n $VIP"
    arp -n "$VIP" 2>/dev/null || echo "(no ARP entry for $VIP yet)"
  elif command -v ip >/dev/null 2>&1; then
    echo "== ip neigh show $VIP"
    ip neigh show "$VIP" 2>/dev/null || echo "(no neighbour entry for $VIP yet)"
  else
    echo "== no arp(8) or ip(8) on this host"
  fi
}

print_leases() {
  local ctx=$1
  echo "-- ${ctx#kind-} l2announce leases"
  kubectl --context "$ctx" -n kube-system get leases 2>/dev/null | grep l2announce || echo "(none)"
}

holder_of() {
  # whitespace-safe: kubectl jsonpath on an empty holderIdentity still prints a newline,
  # and [ -n $'\n' ] is true — a dying lease must not count as a second announcer.
  local ctx=$1 id
  id=$(kubectl --context "$ctx" -n kube-system get lease "$LEASE_GREP" \
        -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  id=${id//$'\r'/}
  id=${id//$'\n'/}
  id=${id//[[:space:]]/}
  printf '%s' "$id"
}

who_announces() {
  local holder="" ctx id
  for ctx in kind-poc1 kind-poc2; do
    id=$(holder_of "$ctx")
    if [ -n "$id" ]; then
      if [ -n "$holder" ]; then
        echo "BOTH ($holder and ${ctx#kind-})"
        return
      fi
      holder=${ctx#kind-}
    fi
  done
  echo "${holder:-none}"
}

reachable() { # ctx — the API answers at all (an unreachable cluster is UNKNOWN, not "absent")
  kubectl --context "$1" get --raw /readyz >/dev/null 2>&1
}

status() {
  echo "== VIP $VIP announced by: $(who_announces)"
  for ctx in kind-poc1 kind-poc2; do
    echo "-- ${ctx#kind-}"
    if ! reachable "$ctx"; then
      echo "  API unreachable — announcer state UNKNOWN (its agents may still hold the VIP)"
      continue
    fi
    if kubectl --context "$ctx" get ciliuml2announcementpolicy shop-vip-announce >/dev/null 2>&1; then
      echo "  shop-vip-announce: present"
    else
      echo "  shop-vip-announce: absent"
    fi
    id=$(holder_of "$ctx")
    if [ -n "$id" ]; then
      echo "  lease holder=$id"
    else
      if kubectl --context "$ctx" -n kube-system get lease "$LEASE_GREP" >/dev/null 2>&1; then
        echo "  lease holder= (dying, empty holderIdentity)"
      else
        echo "  lease: none"
      fi
    fi
  done
  print_arp
}

if [ "${1:-}" = "--status" ] || [ "${1:-}" = "-s" ]; then
  status
  exit 0
fi

TARGET=$(ctx_of "${1:-}")
FORCE=0
case "${2:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) echo "usage: $0 poc1|poc2 [--force] | --status" >&2; exit 2 ;;
esac
OTHER=kind-poc2
if [ "$TARGET" = "kind-poc2" ]; then
  OTHER=kind-poc1
fi

echo "== takeover: ${TARGET#kind-} will announce $VIP (delete ${OTHER#kind-} first)"
if ! kubectl --context "$OTHER" delete ciliuml2announcementpolicy shop-vip-announce --ignore-not-found; then
  if [ "$FORCE" -ne 1 ]; then
    echo "vip-takeover: could not delete shop-vip-announce from ${OTHER#kind-}; refusing to apply to ${TARGET#kind-}" >&2
    echo "vip-takeover: if ${OTHER#kind-}'s API is down (DR), re-run with --force — its agents may still announce $VIP" >&2
    exit 1
  fi
  echo "WARNING: ${OTHER#kind-} unreachable — --force given, applying to ${TARGET#kind-} anyway; ${OTHER#kind-}'s agents may still announce $VIP" >&2
fi
kubectl --context "$TARGET" apply -f "$POLICY"
echo "== l2announce leases after"
print_leases "$TARGET"
print_leases "$OTHER"
print_arp
echo "== VIP $VIP announced by: $(who_announces)"
