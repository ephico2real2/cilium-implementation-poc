#!/usr/bin/env bash
# test: demo 52 apply.sh grpc_matrix records every row and never aborts
# mid-function, but returns non-zero when any row is FAIL (A9). PATH-stub:
# `go` (grpcurl) and `curl`; grpc_matrix is extracted and run alone.
#   (a) a go stub that fails one test → the function returns non-zero
#   (b) a go stub that satisfies every judge → the function returns 0
# usage: bash tests/apply52-matrix-fail.sh [demos/52-eg-poc2-metallb/apply.sh]
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
APPLY=${1:-$R/demos/52-eg-poc2-metallb/apply.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/52-eg-poc2-metallb/probe"
{
  echo 'GRPC_HOST=grpc.eg-poc2.poc.local; GRPC_ADDR=172.19.255.151; HTTP_HOST=api.eg-poc2.poc.local; HTTP_ADDR=172.19.255.150; CA=/dev/null'
  sed -n '/^grpc_matrix() {$/,/^}$/p' "$APPLY"
  echo 'grpc_matrix'
} > "$T/repo/matrix.sh"
grep -q '^grpc_matrix() {$' "$T/repo/matrix.sh" || { echo "TEST FAIL: grpc_matrix not found in $APPLY"; exit 1; }
printf '#!/usr/bin/env bash\nprintf 404\n' > "$T/bin/curl"
chmod +x "$T/bin/curl"

LIST_V1='{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v1-aaaa","version":"v1"}],"servedBy":"grpcdemo-v1-aaaa","version":"v1"}'
LIST_V2='{"orders":[{"id":"1","item":"keyboard","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"},{"id":"3","item":"monitor","servedBy":"grpcdemo-v2-bbbb","version":"v2"}],"servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
GET_V2='{"id":"2","item":"mouse","servedBy":"grpcdemo-v2-bbbb","version":"v2"}'
WATCH='{"order":{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},"servedBy":"grpcdemo-v1-aaaa","version":"v1"}
{"order":{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},"servedBy":"grpcdemo-v1-aaaa","version":"v1"}
{"order":{"id":"3","item":"monitor","servedBy":"grpcdemo-v1-aaaa","version":"v1"},"servedBy":"grpcdemo-v1-aaaa","version":"v1"}
{"order":{"id":"1","item":"keyboard","servedBy":"grpcdemo-v1-aaaa","version":"v1"},"servedBy":"grpcdemo-v1-aaaa","version":"v1"}
{"order":{"id":"2","item":"mouse","servedBy":"grpcdemo-v1-aaaa","version":"v1"},"servedBy":"grpcdemo-v1-aaaa","version":"v1"}'

# (a) every call fails to dial — at least T1 (and T11) FAIL; the function must return ≠ 0
cat > "$T/bin/go" <<'STUB'
#!/usr/bin/env bash
printf 'Failed to dial target host "172.19.255.151:443": context deadline exceeded\n'
exit 1
STUB
chmod +x "$T/bin/go"
set +e
(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash matrix.sh >"$T/out-fail" 2>/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "TEST FAIL: grpc_matrix returned 0 when a test FAILed"; grep '^T T' "$T/out-fail"; exit 1; }
grep -qE 'gRPC matrix: [1-9][0-9]* FAIL' "$T/out-fail" \
  || { echo "TEST FAIL: grpc_matrix did not print 'gRPC matrix: N FAIL' on a FAIL row"; cat "$T/out-fail"; exit 1; }

# (b) a stub that satisfies every judge — the function must return 0
cat > "$T/bin/go" <<STUB
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"-cacert /dev/null"* ]]; then
  printf '%s\n' '$LIST_V1'
  exit 0
fi
if [[ "\$args" == *"-cacert"* ]]; then
  printf 'tls: failed to verify certificate: x509: certificate signed by unknown authority\n'
  exit 1
fi
if [[ "\$args" == *Nope/Do* ]]; then
  printf 'ERROR:\n  Code: Unimplemented\n  Message:\n'
  exit 1
fi
if [[ "\$args" == *NoSuchMethod* ]]; then
  printf 'ERROR:\n  Code: Unimplemented\n  Message: unknown method NoSuchMethod for service shop.v1.Orders\n'
  exit 1
fi
if [[ "\$args" == *SlowOrder* ]]; then
  printf 'ERROR:\n  Code: DeadlineExceeded\n  Message: context deadline exceeded\n'
  exit 1
fi
if [[ "\$args" == *'{"id":99}'* ]]; then
  printf 'ERROR:\n  Code: NotFound\n  Message: order 99 not found\n'
  exit 1
fi
if [[ "\$args" == *GetOrder* ]]; then
  printf '%s\n' '$GET_V2'
  exit 0
fi
if [[ "\$args" == *WatchOrders* ]]; then
  printf '%s\n' '$WATCH'
  exit 0
fi
if [[ "\$args" == *172.19.255.150* ]]; then
  printf 'server does not support the reflection API\n'
  exit 1
fi
if [[ "\$args" == *Health/Check* ]]; then
  printf '{"status":"SERVING"}\n'
  exit 0
fi
if [[ "\$args" == *describe* ]]; then
  printf 'ListOrders GetOrder WatchOrders SlowOrder\n'
  exit 0
fi
if [[ "\$args" == *"list"* && "\$args" != *ListOrders* ]]; then
  printf 'grpc.health.v1.Health\nshop.v1.Orders\n'
  exit 0
fi
if [[ "\$args" == *"-v "* ]] || [[ "\$args" == *"-v" ]]; then
  printf 'x-served-by: grpcdemo-v1-aaaa\nx-version: v1\n%s\n' '$LIST_V1'
  exit 0
fi
if [[ "\$args" == *x-version* ]]; then
  printf '%s\n' '$LIST_V2'
  exit 0
fi
printf '%s\n' '$LIST_V1'
exit 0
STUB
chmod +x "$T/bin/go"
set +e
(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash matrix.sh >"$T/out-pass" 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "TEST FAIL: grpc_matrix returned $rc when every judge should PASS"; grep '^T T' "$T/out-pass"; exit 1; }
grep -qE 'gRPC matrix: 0 FAIL' "$T/out-pass" \
  || { echo "TEST FAIL: grpc_matrix did not print 'gRPC matrix: 0 FAIL' when all rows PASS"; grep '^T T' "$T/out-pass"; exit 1; }
fails=$(printf '%s\n' "$(grep -cE '^T T[0-9].* FAIL$' "$T/out-pass" || true)")
[ "$fails" -eq 0 ] || { echo "TEST FAIL: expected 0 FAIL rows on the all-pass stub, got $fails"; grep '^T T' "$T/out-pass"; exit 1; }

echo "TEST PASS: grpc_matrix returns non-zero when a row FAILs and 0 when every row PASSes"
exit 0
