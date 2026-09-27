#!/usr/bin/env bash
# test: poc1-colima-up.sh / -down.sh accept exactly one lab — CTX=colima-cilium-poc1 with profile cilium-poc1 — and
# refuse Docker Desktop, the fabric's own VM and a mismatched pair before any docker daemon or colima call; and the
# fabric's scripts keep refusing colima-cilium-poc1 even with FABRIC_COLIMA_EXPECT_CTX in the environment (the lib
# assigns it, so only a script that sets it after sourcing — the poc1 pair — widens its own gate).
# usage: bash tests/poc1-colima-gate.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# docker: log every call; the context exists, its VM is down — so a script that passes the name gate stops at
# fabric_colima_require_ctx, having asked only `context inspect` and `info`
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "DOCKER $*" >> "$LOG"
case "$*" in
  'context show') echo desktop-linux; exit 0 ;;
  'context inspect '*) echo '{}'; exit 0 ;;
  *' info'*) echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
  *) echo "stub: unexpected docker $*" >&2; exit 99 ;;
esac
STUB
# the stubs' bodies are literal ($* and $LOG are theirs, not this script's)
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "COLIMA $*" >> "$LOG"; exit 1\n' > "$T/bin/colima"
# shellcheck disable=SC2016
for t in kind kubectl helm cilium; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"; exit 1\n' "$t" > "$T/bin/$t"; done
chmod +x "$T/bin/"*

fail=0
run() { # <script> <want: refuse|pass> <env…>
  local script=$1 want=$2 rc=0; shift 2
  : > "$T/log"
  (cd "$R" && env "$@" LOG="$T/log" PATH="$T/bin:/usr/bin:/bin" bash "$script" >/dev/null 2>"$T/err") || rc=$?
  if [ "$want" = refuse ]; then
    if [ "$rc" -eq 0 ] || ! grep -q refusing "$T/err" || [ -s "$T/log" ]; then
      echo "FAIL: $script $* — want a refusal before any docker/colima call (rc=$rc)"; cat "$T/err" "$T/log"; fail=1
    fi
  else
    # the name gate passed: it asked the daemon, then stopped at "not running" — never beyond `info`
    if ! grep -q "context inspect colima-cilium-poc1" "$T/log" || ! grep -q 'not running' "$T/err" \
       || grep -vE '^DOCKER (context (inspect|show)|--context colima-cilium-poc1 info)' "$T/log" | grep -q .; then
      echo "FAIL: $script $* — want the gate passed and a stop at the VM check"; cat "$T/err" "$T/log"; fail=1
    fi
  fi
}

for s in scripts/poc1-colima-up.sh scripts/poc1-colima-down.sh; do
  run "$s" refuse CTX=desktop-linux
  run "$s" refuse CTX=default
  run "$s" refuse CTX=colima-bgp-fabric FABRIC_COLIMA_PROFILE=bgp-fabric
  run "$s" refuse CTX=colima-cilium-poc1 FABRIC_COLIMA_PROFILE=bgp-fabric
  run "$s" pass
  run "$s" pass CTX=colima-cilium-poc1 FABRIC_COLIMA_PROFILE=cilium-poc1
done
# the fabric's gate cannot be widened from the environment
run scripts/fabric-colima-status.sh refuse CTX=colima-cilium-poc1 FABRIC_COLIMA_PROFILE=cilium-poc1 FABRIC_COLIMA_EXPECT_CTX=colima-cilium-poc1
run scripts/eg-colima-up.sh refuse CTX=colima-cilium-poc1 FABRIC_COLIMA_PROFILE=cilium-poc1 FABRIC_COLIMA_EXPECT_CTX=colima-cilium-poc1

[ "$fail" -eq 0 ] || { echo "TEST FAIL"; exit 1; }
echo "TEST PASS: poc1-colima-up/down accept only colima-cilium-poc1 + cilium-poc1; Desktop, the fabric's VM and a mismatched pair refuse before any daemon call; the fabric's gate cannot be widened from the environment"
