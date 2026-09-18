#!/usr/bin/env bash
# test: the "no Cilium DaemonSet" row must FAIL when kubectl cannot reach the cluster.
# usage: bash tests/check50-cilium-row.sh demos/50-eg-clusters/check.sh   (exit 0 = test passes)
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/50-eg-clusters" "$T/repo/scripts/bootstrap"
cp "$CHECK" "$T/repo/demos/50-eg-clusters/check.sh"
printf 'GATEWAY_API_VERSION=v1.6.2\nCERT_MANAGER_VERSION=v1.21.1\n' > "$T/repo/scripts/bootstrap/versions-eg.env"
printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/helm"; cp "$T/bin/helm" "$T/bin/docker"; chmod +x "$T/bin/"*
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/50-eg-clusters/check.sh 2>/dev/null)
if printf '%s\n' "$out" | grep -qE '^  PASS +eg1 no Cilium DaemonSet'; then echo "TEST FAIL: a dead kubectl produced a PASS row"; exit 1; fi
printf '%s\n' "$out" | grep -qE '^  FAIL +eg1 no Cilium DaemonSet' && { echo "TEST PASS: dead kubectl -> FAIL row"; exit 0; }
echo "TEST FAIL: row missing"; exit 1
