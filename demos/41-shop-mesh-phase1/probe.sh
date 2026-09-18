#!/usr/bin/env bash
# probe.sh — both shopctl clients against https://api.shop.poc.local. Requires the /etc/hosts
# lines (clients have no --resolve). On Darwin use dscacheutil; on Linux, getent.
#
# Expect in phase 1: /healthz 200, /ready 503, /orders 503 (no database until phase 2).
# Exit code is the Go client's (failed checks); 503s on /ready and /orders are honest fails.
#
#   demos/41-shop-mesh-phase1/probe.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
TRANSCRIPT=demos/41-shop-mesh-phase1/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

HOST=api.shop.poc.local
URL="https://$HOST"
CA="${ROOT_CA:-docs/root-ca.crt}"
PY=demos/40-shop-mesh-phase0/client/python/shopctl.py

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
esac
GO_BIN="demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-${os}-${arch}"

echo "== hosts-entries.sh (the four names this probe needs)"
rec demos/40-shop-mesh-phase0/hosts-entries.sh

live_vip() {
  kubectl --context "${VIP_CONTEXT:-kind-poc1}" -n shop-edge \
    get gateway shop-vip-gw -o jsonpath='{.status.addresses[0].value}' \
    2>/dev/null
}

resolved_addresses() {
  local host=$1
  if [ "$(uname -s)" = Darwin ]; then
    dscacheutil -q host -a name "$host" 2>/dev/null |
      awk '$1=="ip_address:" {print $2}'
  else
    getent hosts "$host" 2>/dev/null | awk '{print $1}'
  fi
}

check_resolution() {
  local host=$1 expected=$2 addresses
  addresses=$(resolved_addresses "$host")
  [ -n "$addresses" ] || return 1
  printf '%s\n' "$addresses" | grep -Fxq "$expected"
}

VIP=$(live_vip || true)
if [ -z "$VIP" ]; then
  echo "probe.sh: cannot read the live address of shop-edge/shop-vip-gw." >&2
  exit 2
fi
if ! check_resolution "$HOST" "$VIP"; then
  actual=$(resolved_addresses "$HOST" | paste -sd, -)
  echo "probe.sh: $HOST resolves to ${actual:-nothing}; live VIP is $VIP." >&2
  echo "Replace the stale hosts entry with the block above:" >&2
  echo "  demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts" >&2
  exit 2
fi

if [ ! -x "$GO_BIN" ]; then
  echo "probe.sh: $GO_BIN is missing — demo 40's client/go/shopctl/build.sh writes it (do not rebuild during this phase on the Mac; gotcha #118)." >&2
  exit 2
fi

echo "== shopctl (Go) probe --cacert"
go_rc=0
rec "$GO_BIN" probe --url "$URL" --cacert "$CA" || go_rc=$?

echo "== shopctl.py probe --cacert"
py_rc=0
rec python3 "$PY" probe --url "$URL" --cacert "$CA" || py_rc=$?

echo "== --insecure variant (once, Go)"
insec_rc=0
rec "$GO_BIN" probe --url "$URL" --insecure || insec_rc=$?

echo "probe.sh: go_rc=$go_rc py_rc=$py_rc insecure_rc=$insec_rc (phase 1: /ready and /orders are 503, so two fails is the honest state)"
# the Go client's exit is the number of failed checks; do not hide it
exit "$go_rc"
