#!/usr/bin/env bash
# test: the dashboard image is stamped with the commit of the code that built
# it — which is bgp-fabric's commit, not this repository's.
#
#   (a) bgp-fabric's build-revision.sh prints ITS HEAD, and marks a dirty tree
#   (b) scripts/fabric-up.sh passes that to `docker build` as --build-arg
#   (c) scripts/fabric-colima-up.sh does the same
#   (d) the build CONTEXT — not only the -f path — is the bgp-fabric tree
#   (e) the router agent is built from that tree too, by both scripts
#
# The distinction in (a) is the point. The dashboard source lives in
# bgp-fabric now; a sha taken from THIS repository would name a commit whose
# tree does not contain the code being built, which is the exact failure the
# stamp exists to catch (measured 2026-09-23: the lab served `build 4cf1864`,
# a commit with neither the endpoint nor the label function in its tree).
#
# Two fixture repositories with DIFFERENT heads, so a script that reached for
# the wrong one cannot accidentally pass. The scripts are RUN, with a `docker`
# that records argv and fails at `compose up` so the run stops after the
# build — grepping the script text would pass on a line that is never reached.
#   usage: bash tests/dashboard-build-args.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# --- the stand-in for bgp-fabric -------------------------------------------
# build-revision.sh is bgp-fabric's, and this fixture takes it from there
# rather than from a copy here: a second copy in this repository would drift
# from the one the lab actually runs, and the gate would be testing the copy.
SRC=$(BGP_FABRIC_DIR="${BGP_FABRIC_DIR:-}" "$R/scripts/bgp-fabric-fetch.sh" 2>/dev/null) \
  || { echo "TEST FAIL: could not fetch the pinned bgp-fabric tree"; exit 1; }
mkdir -p "$T/fabric/scripts" "$T/fabric/dashboard" "$T/fabric/frr-agent" "$T/fabric/fabric"
cp "$SRC/scripts/build-revision.sh" "$T/fabric/scripts/build-revision.sh" \
  || { echo "TEST FAIL: bgp-fabric has no scripts/build-revision.sh"; exit 1; }
printf 'FROM scratch\n' > "$T/fabric/dashboard/Containerfile"
printf 'FROM scratch\n' > "$T/fabric/frr-agent/Containerfile"
printf 'name: x\n' > "$T/fabric/fabric/compose.yaml"
git -C "$T/fabric" init -q
git -C "$T/fabric" add -A
git -C "$T/fabric" -c user.email=t@t -c user.name=t commit -qm "fabric fixture"
SHA_FABRIC=$(git -C "$T/fabric" rev-parse HEAD)

# --- the stand-in for this repository --------------------------------------
mkdir -p "$T/bin" "$T/home" "$T/repo/scripts/bootstrap" \
  "$T/repo/demos/55-bgp-fabric-desktop/fabric" "$T/repo/demos/46-bgp-fabric-colima/fabric"
for s in fabric-up.sh fabric-colima-up.sh fabric-colima-lib.sh record.sh \
         bgp-fabric-fetch.sh bgp-fabric.env bgp-fabric-images.sh; do
  cp "$R/scripts/$s" "$T/repo/scripts/$s" \
    || { echo "TEST FAIL: scripts/$s does not exist"; exit 1; }
done
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env" \
  || { echo "TEST FAIL: scripts/bootstrap/versions-eg.env does not exist"; exit 1; }
printf 'name: x\n' > "$T/repo/demos/55-bgp-fabric-desktop/fabric/compose.yaml"
printf 'name: x\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"
printf 'lab fixture\n' > "$T/repo/README.md"
git -C "$T/repo" init -q
git -C "$T/repo" add -A
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm "lab fixture"
SHA_LAB=$(git -C "$T/repo" rev-parse HEAD)

# The whole test rests on being able to tell the two apart.
[ "$SHA_LAB" != "$SHA_FABRIC" ] || { echo "TEST FAIL: both fixtures have the same HEAD"; exit 1; }

# The stub records argv and answers the few questions the up-scripts ask.
# `image inspect` says "absent" so a build always happens; `inspect -f
# {{...revision}}` replays whatever the last build was stamped with, so
# fabric_verify_images sees a coherent answer and the script runs to the end —
# a stub that failed that check would stop the run before the second image.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  *"--build-arg REVISION="*)
    printf '%s\n' "$*" | sed -n 's/.*--build-arg REVISION=\([^ ]*\).*/\1/p' > "${DOCKER_LOG}.rev"
    exit 0 ;;
esac
case "$*" in
  *"image inspect"*)   exit 1 ;;
  *"inspect -f"*revision*) cat "${DOCKER_LOG}.rev" 2>/dev/null; exit 0 ;;
  *compose*up*)        exit 1 ;;
  *"context inspect"*) echo 'unix:///dev/null'; exit 0 ;;
  *)                   exit 0 ;;
esac
STUB
cat > "$T/bin/colima" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) echo '{"name":"bgp-fabric","address":"192.168.64.9"}' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/bin/docker" "$T/bin/colima"
mkdir -p "$T/home/.colima/bgp-fabric"

run() {
  DOCKER_LOG="$2" HOME="$T/home" BGP_FABRIC_DIR="$T/fabric" \
    PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "cd '$T/repo' && bash scripts/$1" >/dev/null 2>&1
}

fail=0
# The build CONTEXT is the LAST word of the command line. Testing the whole
# line for the tree's path is satisfied by the `-f .../Containerfile`
# argument on its own, so a script that kept -f and built a different
# directory would pass — measured: reverting only the context to
# `demos/55-bgp-fabric-desktop/dashboard` left this gate green.
context_of() { local line=$1; printf '%s' "${line##* }"; }

want_arg() {
  local log=$1 label=$2 sha=$3 line ctx
  # Selected by the TAG it is built as. --build-arg REVISION no longer tells
  # the two images apart (scripts/bgp-fabric-images.sh stamps both), and
  # selecting on -f or on the context would pre-assume what is being asserted.
  line=$(grep -E '(^| )build .*-t bgp-dashboard:' "$log" | head -1)
  if [ -z "$line" ]; then
    echo "FAIL: $label did not build the dashboard image at all"
    grep -E '(^| )build ' "$log" | sed 's/^/        /'
    fail=1
    return
  fi
  case "$line" in
    *"--build-arg REVISION=$sha"*) ;;
    *"--build-arg REVISION=$SHA_LAB"*)
      echo "FAIL: $label stamped THIS repository's HEAD, not bgp-fabric's:"
      echo "      $line"; fail=1 ;;
    *) echo "FAIL: $label passed a revision that is not bgp-fabric's HEAD ($sha):"
       echo "      $line"; fail=1 ;;
  esac
  case "$line" in
    *"--build-arg BUILT="[0-9][0-9][0-9][0-9]-*) ;;
    *) echo "FAIL: $label passed no RFC-3339 BUILT:"; echo "      $line"; fail=1 ;;
  esac
  case "$line" in
    *"-f $T/fabric/dashboard/Containerfile"*) ;;
    *) echo "FAIL: $label did not use bgp-fabric's dashboard Containerfile:"
       echo "      $line"; fail=1 ;;
  esac
  ctx=$(context_of "$line")
  if [ "$ctx" != "$T/fabric/dashboard" ]; then
    echo "FAIL: $label built the dashboard from context $ctx,"
    echo "      want $T/fabric/dashboard — the stamp would name a commit of a"
    echo "      tree that is not what went into the image:"
    echo "      $line"; fail=1
  fi
}

# The agent is built from the same repository and by the same two scripts, and
# nothing else in this gate looks at it: without this, reverting the agent
# build to the deleted `demos/55-bgp-fabric-desktop/frr-agent` passed.
want_agent() {
  local log=$1 label=$2 line ctx
  line=$(grep -E '(^| )build .*-t frr-agent:' "$log" | head -1)
  if [ -z "$line" ]; then
    echo "FAIL: $label never built the router agent"
    grep -E '(^| )build ' "$log" | sed 's/^/        /'
    fail=1
    return
  fi
  case "$line" in
    *"-f $T/fabric/frr-agent/Containerfile"*) ;;
    *) echo "FAIL: $label did not use bgp-fabric's frr-agent Containerfile:"
       echo "      $line"; fail=1 ;;
  esac
  ctx=$(context_of "$line")
  if [ "$ctx" != "$T/fabric/frr-agent" ]; then
    echo "FAIL: $label built the agent from context $ctx, want $T/fabric/frr-agent:"
    echo "      $line"; fail=1
  fi
}

IFS=$'\t' read -r rev built < <(cd "$T/fabric" && bash scripts/build-revision.sh)
[ "$rev" = "$SHA_FABRIC" ] || { echo "FAIL: build-revision.sh on a clean tree = $rev, want $SHA_FABRIC"; fail=1; }
case "$built" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) ;;
  *) echo "FAIL: build-revision.sh BUILT = $built, want an RFC-3339 instant"; fail=1 ;;
esac

run fabric-up.sh "$T/desktop.log"
want_arg "$T/desktop.log" "fabric-up.sh" "$SHA_FABRIC"
want_agent "$T/desktop.log" "fabric-up.sh"
CTX=colima-bgp-fabric run fabric-colima-up.sh "$T/colima.log"
want_arg "$T/colima.log" "fabric-colima-up.sh" "$SHA_FABRIC"
want_agent "$T/colima.log" "fabric-colima-up.sh"

# A dirty bgp-fabric tree must reach the label as -dirty; a dirty LAB tree
# must not, because the lab's state says nothing about the code being built.
echo "edited" >> "$T/fabric/dashboard/Containerfile"
IFS=$'\t' read -r rev _ < <(cd "$T/fabric" && bash scripts/build-revision.sh)
[ "$rev" = "$SHA_FABRIC-dirty" ] || { echo "FAIL: a dirty tree gave $rev, want $SHA_FABRIC-dirty"; fail=1; }
: > "$T/desktop2.log"
run fabric-up.sh "$T/desktop2.log"
want_arg "$T/desktop2.log" "fabric-up.sh on a dirty bgp-fabric tree" "$SHA_FABRIC-dirty"

[ $fail -eq 0 ] || { echo "TEST FAIL: the dashboard image is not stamped with the commit that built it"; exit 1; }
echo "TEST PASS: both fabrics stamp the dashboard image with bgp-fabric's commit"
