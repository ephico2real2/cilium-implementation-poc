#!/usr/bin/env bash
# test: demo 52 apply.sh grpc_matrix — T11 (bogus CA) must PASS only on a TLS
# verification error, never on "any non-zero rc" (a dead door's dial timeout is
# rc=1 too; measured 2026-09-19 against 172.19.255.152: "Failed to dial target
# host ...: context deadline exceeded", rc=1). PATH-stub: `go` (grpcurl) and
# `curl` are stubs; grpc_matrix is extracted from apply.sh and run alone.
#   (a) dial-failure stub for every grpcurl call → the T11 row is FAIL
#   (b) verify-error stub → the T11 row is PASS
# usage: bash tests/apply52-matrix-t11.sh [demos/52-eg-poc2-metallb/apply.sh]   (exit 0 = pass)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
APPLY=${1:-$R/demos/52-eg-poc2-metallb/apply.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/52-eg-poc2-metallb/probe"
# the function alone, then a driver
{
  echo 'GRPC_HOST=grpc.eg-poc2.poc.local; GRPC_ADDR=172.19.255.151; HTTP_HOST=api.eg-poc2.poc.local; HTTP_ADDR=172.19.255.150; CA=/dev/null'
  sed -n '/^grpc_matrix() {$/,/^}$/p' "$APPLY"
  echo 'grpc_matrix'
} > "$T/repo/matrix.sh"
grep -q '^grpc_matrix() {$' "$T/repo/matrix.sh" || { echo "TEST FAIL: grpc_matrix not found in $APPLY"; exit 1; }
printf '#!/usr/bin/env bash\nprintf 404\n' > "$T/bin/curl"
chmod +x "$T/bin/curl"

run_with_go_stub() { # body of the go stub (stdout text), exit code
  printf '#!/usr/bin/env bash\nprintf %%s "%s"\nexit %s\n' "$1" "$2" > "$T/bin/go"
  chmod +x "$T/bin/go"
  (cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash matrix.sh 2>/dev/null)
}

# (a) every grpcurl call fails to dial (dead door) — T11 must not PASS
out=$(run_with_go_stub 'Failed to dial target host "172.19.255.151:443": context deadline exceeded' 1)
if printf '%s\n' "$out" | grep -Eq '^T T11 .* PASS$'; then
  echo "TEST FAIL: T11 PASSed on a dial failure (a dead door would pass the bogus-CA test)"
  printf '%s\n' "$out" | grep '^T T11'
  exit 1
fi
printf '%s\n' "$out" | grep -Eq '^T T11 .* FAIL$' \
  || { echo "TEST FAIL: no T11 row on the dial-failure stub"; printf '%s\n' "$out"; exit 1; }

# (b) the verification error — T11 must PASS
out=$(run_with_go_stub 'Failed to dial target host "172.19.255.151:443": tls: failed to verify certificate: x509: certificate signed by unknown authority' 1)
printf '%s\n' "$out" | grep -Eq '^T T11 .* PASS$' \
  || { echo "TEST FAIL: T11 did not PASS on the x509 verification error"; printf '%s\n' "$out" | grep '^T T11'; exit 1; }

echo "TEST PASS: T11 is FAIL on a dial failure and PASS on 'tls: failed to verify certificate'"
exit 0
