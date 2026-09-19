#!/usr/bin/env bash
# test: demo 54 check.sh / apply.sh contract (PATH-stub).
#   (a) a dead kubectl produces FAIL rows (never PASS) and exit ≠ 0
#   (b) the gRPC rows FAIL on {"status":"NOT_SERVING"}
#   (c) no `-k`/`-sk` and no `|| echo 000` in apply.sh or check.sh
# usage: bash tests/check54-contract.sh   (exit 0 = test passes)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/54-eg-poc1-kube-vip/check.sh
APPLY=$R/demos/54-eg-poc1-kube-vip/apply.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/54-eg-poc1-kube-vip"
cp "$CHECK" "$T/repo/demos/54-eg-poc1-kube-vip/check.sh"
cp "$APPLY" "$T/repo/demos/54-eg-poc1-kube-vip/apply.sh"

printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 000\nexit 7\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"status":"NOT_SERVING"}\n'"'"'\nexit 0\n' > "$T/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/kind"
chmod +x "$T/bin/"*

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/54-eg-poc1-kube-vip/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}

if printf '%s\n' "$out" | grep -qE '^  PASS'; then
  echo "TEST FAIL: a dead kubectl produced a PASS row"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out" | grep -qE '^  FAIL' \
  || { echo "TEST FAIL: dead kubectl — no FAIL rows"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: dead kubectl — check.sh exited 0"; exit 1; }

printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC h2c' \
  || { echo "TEST FAIL: gRPC h2c FAIL row missing on NOT_SERVING"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC h2c'; then
  echo "TEST FAIL: NOT_SERVING was accepted as SERVING"
  exit 1
fi

if grep -nE -- '-sk|[[:space:]]-k[[:space:]]|[[:space:]]-k"' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry a skip-verify flag"
  exit 1
fi
if grep -nF '|| echo 000' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry || echo 000"
  exit 1
fi

echo "TEST PASS: dead kubectl → FAIL (never PASS, exit ≠ 0); NOT_SERVING is FAIL; no skip-verify, no || echo 000"
exit 0
