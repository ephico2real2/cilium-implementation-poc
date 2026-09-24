#!/usr/bin/env bash
# test: the lab PULLS the published images by default and BUILDS only when
# nothing published can correspond to the source it was pointed at.
#
#   (a) a clean pin, no BGP_FABRIC_DIR      -> pull the sha- tag, re-tag it
#   (b) FABRIC_IMAGE_SOURCE=build           -> build, never pull
#   (c) BGP_FABRIC_DIR set                  -> build, without being asked
#   (d) a -dirty revision                   -> build, without being asked
#   (e) an image whose label disagrees with the pin -> the run stops
#
# (c) and (d) are the ones worth a gate. A working checkout and a dirty tree
# are not commits, so no published image can BE them; a pull that succeeded
# anyway would hand the lab someone else's build under the name of the code in
# front of you, and the page would name a commit that is not what is running.
#
# The scripts are RUN against a `docker` that records argv, so a decision that
# is written but never reached cannot pass.
#   usage: bash tests/bgp-fabric-images.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
fail=0

# --- the stand-in for bgp-fabric -------------------------------------------
SRC=$(BGP_FABRIC_DIR="${BGP_FABRIC_DIR:-}" "$R/scripts/bgp-fabric-fetch.sh" 2>/dev/null) \
  || { echo "TEST FAIL: could not fetch the pinned bgp-fabric tree"; exit 1; }
mkdir -p "$T/fabric/scripts" "$T/fabric/dashboard" "$T/fabric/frr-agent" "$T/fabric/fabric"
cp "$SRC/scripts/build-revision.sh" "$T/fabric/scripts/build-revision.sh" \
  || { echo "TEST FAIL: bgp-fabric has no scripts/build-revision.sh"; exit 1; }
printf 'FROM scratch\n' > "$T/fabric/dashboard/Containerfile"
printf 'FROM scratch\n' > "$T/fabric/frr-agent/Containerfile"
git -C "$T/fabric" init -q
git -C "$T/fabric" add -A
git -C "$T/fabric" -c user.email=t@t -c user.name=t commit -qm "fabric fixture"
SHA=$(git -C "$T/fabric" rev-parse HEAD)
SHORT=$(printf '%s' "$SHA" | cut -c1-7)

# --- the stand-in for this repository --------------------------------------
mkdir -p "$T/bin" "$T/home" "$T/repo/scripts/bootstrap" "$T/repo/demos/55-bgp-fabric-desktop/fabric"
for s in fabric-up.sh fabric-colima-lib.sh record.sh bgp-fabric.env bgp-fabric-images.sh; do
  cp "$R/scripts/$s" "$T/repo/scripts/$s" \
    || { echo "TEST FAIL: scripts/$s does not exist"; exit 1; }
done
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env" \
  || { echo "TEST FAIL: scripts/bootstrap/versions-eg.env does not exist"; exit 1; }
printf 'name: x\n' > "$T/repo/demos/55-bgp-fabric-desktop/fabric/compose.yaml"
# A fetch that hands over the fixture WITHOUT setting BGP_FABRIC_DIR, so the
# pull path is reachable here. Setting the variable is itself a build trigger,
# which is what case (c) is for.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$T/fabric" > "$T/repo/scripts/bgp-fabric-fetch.sh"
chmod +x "$T/repo/scripts/bgp-fabric-fetch.sh"

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  *"--build-arg REVISION="*)
    printf '%s\n' "$*" | sed -n 's/.*--build-arg REVISION=\([^ ]*\).*/\1/p' > "${DOCKER_LOG}.rev"
    exit 0 ;;
  *" pull "*) printf '%s\n' "$FAKE_REVISION" > "${DOCKER_LOG}.rev"; exit 0 ;;
esac
case "$*" in
  *"image inspect"*)       exit 1 ;;
  *"inspect -f"*revision*) cat "${DOCKER_LOG}.rev" 2>/dev/null; exit 0 ;;
  *compose*up*)            exit 1 ;;
  *"context inspect"*)     echo 'unix:///dev/null'; exit 0 ;;
  *)                       exit 0 ;;
esac
STUB
chmod +x "$T/bin/docker"

run() { # log   [env assignments...]
  local log=$1; shift
  : > "$log"
  env DOCKER_LOG="$log" HOME="$T/home" FAKE_REVISION="${FAKE_REVISION:-$SHA}" \
    PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@" \
    bash -c "cd '$T/repo' && bash scripts/fabric-up.sh" >/dev/null 2>&1
}
has()  { grep -qE "$2" "$1"; }
want() { # log  label  regex  present(yes|no)
  if has "$1" "$3"; then [ "$4" = yes ] || { echo "FAIL: $2 — did not expect /$3/"; sed 's/^/        /' "$1"; fail=1; }
  else [ "$4" = no ] || { echo "FAIL: $2 — expected /$3/"; sed 's/^/        /' "$1"; fail=1; }
  fi
}

# (a) a clean pin and no local checkout: pull, re-tag, never build
run "$T/a.log"
want "$T/a.log" "default"  "pull quay.io/ephico2real/bgp-fabric-agent:sha-$SHORT"     yes
want "$T/a.log" "default"  "pull quay.io/ephico2real/bgp-fabric-dashboard:sha-$SHORT" yes
want "$T/a.log" "default"  "tag quay.io/ephico2real/bgp-fabric-agent:sha-$SHORT frr-agent:local" yes
want "$T/a.log" "default"  "(^| )build "                                             no

# (b) asked to build
run "$T/b.log" FABRIC_IMAGE_SOURCE=build
want "$T/b.log" "FABRIC_IMAGE_SOURCE=build" "(^| )build .*-t frr-agent:local"     yes
want "$T/b.log" "FABRIC_IMAGE_SOURCE=build" "(^| )build .*-t bgp-dashboard:local" yes
want "$T/b.log" "FABRIC_IMAGE_SOURCE=build" " pull "                              no

# (c) a working checkout: build, without being asked
run "$T/c.log" BGP_FABRIC_DIR="$T/fabric"
want "$T/c.log" "BGP_FABRIC_DIR set" "(^| )build .*-t bgp-dashboard:local" yes
want "$T/c.log" "BGP_FABRIC_DIR set" " pull "                              no

# (d) a dirty tree: build, without being asked. Nothing published can be it.
echo "edited" >> "$T/fabric/dashboard/Containerfile"
run "$T/d.log"
want "$T/d.log" "a dirty tree" "(^| )build .*--build-arg REVISION=$SHA-dirty" yes
want "$T/d.log" "a dirty tree" " pull "                                       no
git -C "$T/fabric" checkout -q -- dashboard/Containerfile

# (e) an image that names a different commit must stop the run, not be used
FAKE_REVISION=0000000000000000000000000000000000000000 run "$T/e.log"
if env DOCKER_LOG="$T/e2.log" HOME="$T/home" FAKE_REVISION=0000000000000000000000000000000000000000 \
     PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
     bash -c "cd '$T/repo' && bash scripts/fabric-up.sh" >/dev/null 2>&1; then
  echo "FAIL: an image labelled with the wrong revision did not stop the run"
  fail=1
fi
want "$T/e2.log" "wrong-revision image" "compose .*up" no

[ $fail -eq 0 ] || { echo "TEST FAIL: the lab does not choose between pulling and building correctly"; exit 1; }
echo "TEST PASS: published images are pulled, and built only when nothing published can match the source"
