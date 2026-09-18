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

resolved=0
if [ "$(uname -s)" = Darwin ]; then
  if dscacheutil -q host -a name "$HOST" 2>/dev/null | grep -q 'ip_address:'; then
    resolved=1
  fi
else
  if getent hosts "$HOST" >/dev/null 2>&1; then
    resolved=1
  fi
fi
if [ "$resolved" -ne 1 ]; then
  echo "probe.sh: $HOST does not resolve on this host." >&2
  echo "Add the block above to /etc/hosts (the script never writes it):" >&2
  echo "  demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts" >&2
  echo "On Darwin the resolver is dscacheutil; on Linux, getent. Then re-run." >&2
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
