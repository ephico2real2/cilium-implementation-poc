#!/usr/bin/env bash
# tls-proof.sh — record the grpc.poc2.shop.poc.local leaf and prove which root
# verifies it. Live .tmp/root-ca.crt → OK; docs/root-ca.crt → failed
# (https://github.com/ephico2real2/cilium-implementation-poc/issues/60).
# apply.sh records this after policy-proof.sh.
#
#   demos/53-grpc-parity/tls-proof.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

SNI=grpc.poc2.shop.poc.local
ADDR=172.18.255.177:443
LIVE=.tmp/root-ca.crt
DOCS=docs/root-ca.crt
LEAF=.tmp/grpc-poc2.crt

[ -s "$LIVE" ] || { echo "tls-proof: missing $LIVE (run scripts/lab-trust.sh export kind-poc2)" >&2; exit 1; }
[ -s "$DOCS" ] || { echo "tls-proof: missing $DOCS" >&2; exit 1; }

echo "== 1. openssl s_client -servername $SNI -connect $ADDR | openssl x509 -noout -subject -issuer -ext subjectAltName -fingerprint -sha256 -dates"
echo | openssl s_client -servername "$SNI" -connect "$ADDR" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName -fingerprint -sha256 -dates

echo | openssl s_client -servername "$SNI" -connect "$ADDR" 2>/dev/null \
  | openssl x509 > "$LEAF"

echo "== 2. openssl verify -CAfile $LIVE $LEAF (want OK)"
live_out=$(openssl verify -CAfile "$LIVE" "$LEAF" 2>&1) || true
printf '%s\n' "$live_out"
printf '%s' "$live_out" | grep -q ': OK$' || {
  echo "tls-proof: live root did not verify $LEAF" >&2
  exit 1
}

echo "== 3. openssl verify -CAfile $DOCS $LEAF (want failed — issue #60)"
docs_out=$(openssl verify -CAfile "$DOCS" "$LEAF" 2>&1) || true
printf '%s\n' "$docs_out"
if printf '%s' "$docs_out" | grep -q ': OK$'; then
  echo "tls-proof: $DOCS unexpectedly verified the live leaf" >&2
  exit 1
fi
printf '%s' "$docs_out" | grep -qiE 'unable to get local issuer certificate|verification failed' || {
  echo "tls-proof: $DOCS failure was not the expected issuer error" >&2
  exit 1
}

echo "tls-proof: live root OK; $DOCS failed (issue #60)"
