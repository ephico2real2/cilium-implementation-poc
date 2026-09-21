#!/usr/bin/env bash
# test: Colima fabric scripts refuse Docker Desktop and a missing profile,
# and never mutate anything outside project bgp-fabric-colima.
# Proves CTX=desktop-linux exits non-zero and creates no container.
# usage: bash tests/fabric-colima-context.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/log"

# --- static: every daemon docker *command* carries --context
# (echo/row strings that mention docker are not commands).
bad=0
for f in \
  "$R/scripts/fabric-colima-up.sh" \
  "$R/scripts/fabric-colima-down.sh" \
  "$R/scripts/fabric-colima-status.sh" \
  "$R/scripts/fabric-colima-lib.sh" \
  "$R/scripts/colima-registry.sh" \
  "$R/scripts/eg-colima-up.sh" \
  "$R/demos/46-bgp-fabric-colima/apply.sh" \
  "$R/demos/46-bgp-fabric-colima/check.sh" \
  "$R/demos/46-bgp-fabric-colima/cleanup.sh" \
  "$R/demos/54-eg-poc1-kube-vip-colima/apply.sh" \
  "$R/demos/54-eg-poc1-kube-vip-colima/check.sh" \
  "$R/demos/54-eg-poc1-kube-vip-colima/cleanup.sh"
do
  # command lines only: leading optional assign/rec/if, then `docker`.
  # docker context {show,use,inspect} are client-side (the restore trap).
  hits=$(grep -nE '^[[:space:]]*(rec[[:space:]]+)?docker[[:space:]]' "$f" \
    | grep -vE 'docker --context|docker context (show|use|inspect)' || true)
  if [ -n "$hits" ]; then
    echo "FAIL: $f has a docker daemon call without --context"
    printf '%s\n' "$hits"
    bad=1
  fi
  if grep -nE 'compose[[:space:]]+-p[[:space:]]+bgp-fabric[[:space:]]' "$f"; then
    echo "FAIL: $f targets project bgp-fabric (Desktop)"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || { echo "TEST FAIL: scripts talk to the wrong engine or project"; exit 1; }

# --- stub docker: log every invocation; never create a container
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "DOCKER $*" >> "${DOCKER_LOG:-/tmp/fabric-colima-docker.log}"
case "$*" in
  'context show') echo desktop-linux; exit 0 ;;
  'context use '*) exit 0 ;;
  'context inspect '*)
    ctx=${*##*inspect }
    ctx=${ctx%% *}
    if [ "$ctx" = colima-bgp-fabric ]; then
      if [ "${STUB_CTX_MISSING:-0}" = 1 ]; then
        echo "context colima-bgp-fabric not found" >&2
        exit 1
      fi
      echo '{"Name":"colima-bgp-fabric"}'
      exit 0
    fi
    echo "context $ctx not found" >&2
    exit 1
    ;;
  *' info'*)
    if [ "${STUB_VM_DOWN:-0}" = 1 ]; then
      echo "Cannot connect to the Docker daemon" >&2
      exit 1
    fi
    echo "Server Version: stub"
    exit 0
    ;;
  *'compose'*up*|*create*|*run '*|*start '*|*build '*)
    echo "stub: refusing mutating docker: $*" >&2
    exit 99
    ;;
  *)
    echo "stub: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$T/bin/docker"
# colima stub: never start a VM
# stub body is literal (the $* is for the stub, not this script).
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "COLIMA $*" >> "${DOCKER_LOG:-/tmp/x}"; echo "stub colima" >&2; exit 1\n' > "$T/bin/colima"
chmod +x "$T/bin/colima"

run() {
  local script=$1 rc=0
  shift
  local extra=()
  case "$script" in
    scripts/colima-registry.sh) extra=(up) ;;
  esac
  ( cd "$R" && env "$@" PATH="$T/bin:/usr/bin:/bin" DOCKER_LOG="$T/log/docker.log" \
      bash "$script" "${extra[@]}" 2>"$T/log/err") || rc=$?
  printf '%s' "$rc"
}

# 1. CTX=desktop-linux — every script refuses; docker is never asked to mutate
: > "$T/log/docker.log"
for script in \
  scripts/fabric-colima-up.sh \
  scripts/fabric-colima-down.sh \
  scripts/fabric-colima-status.sh \
  scripts/colima-registry.sh \
  scripts/eg-colima-up.sh \
  demos/46-bgp-fabric-colima/check.sh \
  demos/46-bgp-fabric-colima/apply.sh \
  demos/46-bgp-fabric-colima/cleanup.sh \
  demos/54-eg-poc1-kube-vip-colima/check.sh \
  demos/54-eg-poc1-kube-vip-colima/apply.sh \
  demos/54-eg-poc1-kube-vip-colima/cleanup.sh
do
  rc=$(run "$script" CTX=desktop-linux)
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $script CTX=desktop-linux exited 0"
    cat "$T/log/err"
    exit 1
  fi
  if ! grep -q 'refusing' "$T/log/err"; then
    echo "FAIL: $script CTX=desktop-linux did not say refusing"
    cat "$T/log/err"
    exit 1
  fi
done
if grep -E 'compose.*up| create | run | build ' "$T/log/docker.log"; then
  echo "FAIL: CTX=desktop-linux still invoked a mutating docker command"
  cat "$T/log/docker.log"
  exit 1
fi

# 2. profile / context missing — CTX is the right name but inspect fails
: > "$T/log/docker.log"
rc=$(run scripts/fabric-colima-status.sh CTX=colima-bgp-fabric STUB_CTX_MISSING=1)
if [ "$rc" -eq 0 ]; then
  echo "FAIL: missing context exited 0"
  cat "$T/log/err"
  exit 1
fi
if ! grep -Eq 'does not exist|refusing' "$T/log/err"; then
  echo "FAIL: missing context did not refuse clearly"
  cat "$T/log/err"
  exit 1
fi
if grep -E 'compose.*up| create | run | build ' "$T/log/docker.log"; then
  echo "FAIL: missing context still mutated"
  cat "$T/log/docker.log"
  exit 1
fi

# 3. live binaries: CTX=desktop-linux — name check fires before any daemon
# call, so Desktop is not contacted and no container can be created.
rc=0
( cd "$R" && CTX=desktop-linux bash scripts/fabric-colima-up.sh ) >/dev/null 2>"$T/log/live-err" || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: live CTX=desktop-linux fabric-colima-up.sh exited 0"; exit 1; }
grep -q 'refusing' "$T/log/live-err" \
  || { echo "FAIL: live CTX=desktop-linux did not refuse"; cat "$T/log/live-err"; exit 1; }

echo "TEST PASS: CTX=desktop-linux refuses (no mutate, no container); missing context refuses; scripts never docker without --context and never target project bgp-fabric"
exit 0
