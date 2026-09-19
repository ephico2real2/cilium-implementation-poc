#!/usr/bin/env bash
# test: a failed redirect probe must report http_code=000, not 000000 (curl already
# prints 000 with -w; an `|| echo 000` doubled it).
# usage: bash tests/check51-curl-000.sh demos/51-eg-kube-vip/check.sh   (exit 0 = test passes)
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/51-eg-kube-vip"
cp "$CHECK" "$T/repo/demos/51-eg-kube-vip/check.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/docker"; printf '#!/usr/bin/env bash\necho "Error from server (NotFound)" >&2; exit 1\n' > "$T/bin/kubectl"
# curl as it really behaves on a refused connection: prints the -w 000 and exits 7
printf '#!/usr/bin/env bash\ncase "$*" in *http_code*) printf 000;; esac\nexit 7\n' > "$T/bin/curl"; chmod +x "$T/bin/"*
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/51-eg-kube-vip/check.sh 2>/dev/null)
if printf '%s\n' "$out" | grep -q 'http_code=000000'; then echo "TEST FAIL: http_code=000000 (doubled)"; exit 1; fi
printf '%s\n' "$out" | grep -qE '^  FAIL +http://api.eg1.poc.local @ [0-9.]+ → 301 +http_code=000 ' || { echo "TEST FAIL: expected FAIL row with http_code=000"; exit 1; }
echo "TEST PASS: failed redirect probe reports http_code=000"
