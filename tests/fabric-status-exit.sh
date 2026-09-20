#!/usr/bin/env bash
# test: fabric-status.sh exits non-zero when a read fails or a session
# is not Established (Codex F5 — measured: six FAIL states, exit 0).
# usage: bash tests/fabric-status-exit.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo 'Cannot connect to the Docker daemon' >&2
exit 1
DOCKER
chmod +x "$T/bin/docker"

rc=0
PATH="$T/bin:$PATH" bash "$R/scripts/fabric-status.sh" >"$T/output" 2>&1 || rc=$?
grep -q 'FAIL' "$T/output"
test "$rc" -ne 0
echo "TEST PASS: fabric-status.sh exits non-zero when docker/session reads fail"
