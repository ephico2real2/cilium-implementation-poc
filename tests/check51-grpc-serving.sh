#!/usr/bin/env bash
# test: gRPC rows must FAIL on {"status":"NOT_SERVING"} — grep SERVING used to
# accept that string.
# usage: bash tests/check51-grpc-serving.sh demos/51-eg-kube-vip/check.sh
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/51-eg-kube-vip"
cp "$CHECK" "$T/repo/demos/51-eg-kube-vip/check.sh"
printf '#!/usr/bin/env bash\necho "Error from server (NotFound)" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 000\nexit 7\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"status":"NOT_SERVING"}\n'"'"'\nexit 0\n' > "$T/bin/docker"
chmod +x "$T/bin/"*
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/51-eg-kube-vip/check.sh 2>/dev/null || true)
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC h2c'; then
  echo "TEST FAIL: NOT_SERVING was accepted as SERVING"
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC h2c' || { echo "TEST FAIL: gRPC h2c FAIL row missing"; exit 1; }
echo "TEST PASS: docker stub {\"status\":\"NOT_SERVING\"} produced FAIL gRPC rows"
