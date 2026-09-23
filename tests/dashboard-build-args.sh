#!/usr/bin/env bash
# test: the dashboard image is stamped with the commit that built it.
#
#   (a) scripts/build-revision.sh prints HEAD, and marks a dirty tree
#   (b) scripts/fabric-up.sh passes it to `docker build` as --build-arg
#   (c) scripts/fabric-colima-up.sh does the same
#
# Without this, every scripted path builds with the Containerfile's default and
# the page reads "local build" while `docker inspect` says revision=unknown —
# measured 2026-09-23, when the feature was dark in its own demo and the one
# running lab was stamped by hand with a sha whose tree did not contain it.
#
# The scripts are RUN, with a `docker` that records argv and fails at
# `compose up` so the run stops after the build. Grepping the script text
# would pass on a line that is never reached.
#   usage: bash tests/dashboard-build-args.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/home" "$T/repo/scripts/bootstrap" \
  "$T/repo/demos/46-bgp-fabric/dashboard" "$T/repo/demos/46-bgp-fabric/fabric" \
  "$T/repo/demos/46-bgp-fabric-colima/dashboard" "$T/repo/demos/46-bgp-fabric-colima/fabric"
for s in fabric-up.sh fabric-colima-up.sh fabric-colima-lib.sh build-revision.sh record.sh; do
  cp "$R/scripts/$s" "$T/repo/scripts/$s" 2>/dev/null || { echo "TEST FAIL: scripts/$s does not exist"; exit 1; }
done
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env" 2>/dev/null || true
printf 'name: x\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: x\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"
printf 'FROM scratch\n' > "$T/repo/demos/46-bgp-fabric/dashboard/Containerfile"
printf 'FROM scratch\n' > "$T/repo/demos/46-bgp-fabric-colima/dashboard/Containerfile"

git -C "$T/repo" init -q
git -C "$T/repo" add -A
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm fixture
SHA=$(git -C "$T/repo" rev-parse HEAD)

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  *"image inspect"*)   exit 1 ;;
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
  DOCKER_LOG="$2" HOME="$T/home" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "cd '$T/repo' && bash scripts/$1" >/dev/null 2>&1
}

fail=0
want_arg() {
  local log=$1 label=$2 sha=$3 line
  line=$(grep -E '(^| )build .*(dashboard|Containerfile)' "$log" | grep -- '--build-arg REVISION=' | head -1)
  if [ -z "$line" ]; then
    echo "FAIL: $label built the dashboard image without --build-arg REVISION"
    grep -E '(^| )build ' "$log" | sed 's/^/        /'
    fail=1
    return
  fi
  case "$line" in
    *"--build-arg REVISION=$sha"*) ;;
    *) echo "FAIL: $label passed a revision that is not HEAD ($sha):"; echo "      $line"; fail=1 ;;
  esac
  case "$line" in
    *"--build-arg BUILT="[0-9][0-9][0-9][0-9]-*) ;;
    *) echo "FAIL: $label passed no RFC-3339 BUILT:"; echo "      $line"; fail=1 ;;
  esac
}

IFS=$'\t' read -r rev built < <(cd "$T/repo" && bash scripts/build-revision.sh)
[ "$rev" = "$SHA" ] || { echo "FAIL: build-revision.sh on a clean tree = $rev, want $SHA"; fail=1; }
case "$built" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) ;;
  *) echo "FAIL: build-revision.sh BUILT = $built, want an RFC-3339 instant"; fail=1 ;;
esac

run fabric-up.sh "$T/desktop.log"
want_arg "$T/desktop.log" "fabric-up.sh" "$SHA"
CTX=colima-bgp-fabric run fabric-colima-up.sh "$T/colima.log"
want_arg "$T/colima.log" "fabric-colima-up.sh" "$SHA"

echo "edited" >> "$T/repo/demos/46-bgp-fabric/dashboard/Containerfile"
IFS=$'\t' read -r rev _ < <(cd "$T/repo" && bash scripts/build-revision.sh)
[ "$rev" = "$SHA-dirty" ] || { echo "FAIL: a dirty tree gave $rev, want $SHA-dirty"; fail=1; }
: > "$T/desktop2.log"
run fabric-up.sh "$T/desktop2.log"
want_arg "$T/desktop2.log" "fabric-up.sh on a dirty tree" "$SHA-dirty"

[ $fail -eq 0 ] || { echo "TEST FAIL: the dashboard image is not stamped with the commit that built it"; exit 1; }
echo "TEST PASS: both fabrics stamp the dashboard image with the commit that built it"
