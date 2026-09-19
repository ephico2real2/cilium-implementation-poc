#!/usr/bin/env bash
# test: the "no metallb-system namespace" row must FAIL when kubectl cannot reach the
# cluster (a dead kubectl is not NotFound) and FAIL when the namespace exists.
# usage: bash tests/check51-metallb-row.sh demos/51-eg-kube-vip/check.sh   (exit 0 = test passes)
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/51-eg-kube-vip"
cp "$CHECK" "$T/repo/demos/51-eg-kube-vip/check.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/docker"; cp "$T/bin/docker" "$T/bin/curl"; chmod +x "$T/bin/"*
run() { (cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/51-eg-kube-vip/check.sh 2>/dev/null); }

# 1. dead kubectl → the row must be FAIL, never PASS
printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"; chmod +x "$T/bin/kubectl"
out=$(run)
if printf '%s\n' "$out" | grep -qE '^  PASS +eg1 no metallb-system namespace'; then echo "TEST FAIL: a dead kubectl produced a PASS row"; exit 1; fi
printf '%s\n' "$out" | grep -qE '^  FAIL +eg1 no metallb-system namespace' || { echo "TEST FAIL: dead kubectl — row missing"; exit 1; }

# 2. namespace exists → FAIL
printf '#!/usr/bin/env bash\ncase "$*" in *"get ns metallb-system"*) echo namespace/metallb-system; exit 0;; esac\necho "Error from server (NotFound)" >&2; exit 1\n' > "$T/bin/kubectl"
out=$(run)
printf '%s\n' "$out" | grep -qE '^  FAIL +eg1 no metallb-system namespace +namespace/metallb-system' || { echo "TEST FAIL: existing namespace not a FAIL"; exit 1; }

# 3. genuine NotFound → PASS
printf '#!/usr/bin/env bash\necho "Error from server (NotFound): namespaces \\"metallb-system\\" not found" >&2; exit 1\n' > "$T/bin/kubectl"
out=$(run)
printf '%s\n' "$out" | grep -qE '^  PASS +eg1 no metallb-system namespace +NotFound' || { echo "TEST FAIL: NotFound not a PASS"; exit 1; }
echo "TEST PASS: dead kubectl -> FAIL, namespace present -> FAIL, NotFound -> PASS"
