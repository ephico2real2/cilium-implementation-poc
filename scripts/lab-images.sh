#!/usr/bin/env bash
# lab-images.sh [cluster…] — the lab's OWN images, built from their Containerfiles and loaded into every kind cluster
# named (default: every cluster kind knows), before any manifest that names them is applied. A kind node pulls from
# registries; an image that exists only in the host's Docker is invisible to it until `kind load` copies it into the
# node's containerd (demo 09 Part 1, demo 15 Part 0). A fresh runner has neither the build nor the load: run
# 34903231161 sat on `deployment "payments" exceeded its progress deadline` with ImagePullBackOff behind it.
#
#   image             built from                       named by
#   bankdemo:local    demos/15-bank/app/Containerfile   demos/15-bank/10-poc2.yaml, 20-poc1.yaml (demos 15, 19, 22, 23, 25)
#   routedemo:local   demos/09-routes/app/Containerfile demos/09-routes/02-apps.yaml (demos 09, 11)
#
# Idempotent: an image already in the host's Docker is not rebuilt (LAB_IMAGES_REBUILD=1 forces it); `kind load` is a
# copy and is repeated — a node that already has the image takes seconds. Add an image: one line in IMAGES below.
# docker build context is demos/ (parent of both apps and of shared/) so the Containerfiles can COPY the shared
# jsonview module; -f still points at the app's Containerfile.
set -euo pipefail; cd "$(dirname "$0")/.."
IMAGES=(
  "bankdemo:local=demos/15-bank/app"
  "routedemo:local=demos/09-routes/app"
)
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }
if [ $# -ge 1 ]; then clusters=("$@"); else read -r -a clusters <<< "$(kind get clusters 2>/dev/null | tr '\n' ' ')"; fi
[ "${#clusters[@]}" -ge 1 ] || die "no kind cluster to load into (scripts/lab-up.sh first)"
say "the lab's images: ${#IMAGES[@]} to build, loaded into ${clusters[*]}"
for spec in "${IMAGES[@]}"; do
  img="${spec%%=*}"; dir="${spec#*=}"
  [ -f "$dir/Containerfile" ] || die "no $dir/Containerfile for $img"
  if [ "${LAB_IMAGES_REBUILD:-0}" != 1 ] && docker image inspect "$img" >/dev/null 2>&1; then
    echo "  $img: present ($(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1048576}')), not rebuilt"
  else
    start=$(date +%s)
    docker build -q -t "$img" -f "$dir/Containerfile" demos >/dev/null || die "docker build of $img from $dir failed"
    echo "  $img: built from $dir in $(( $(date +%s) - start )) s ($(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1048576}'))"
  fi
  for c in "${clusters[@]}"; do
    kind load docker-image "$img" --name "$c" >/dev/null 2>&1 || die "kind load of $img into $c failed"
    printf '  %-16s → %s: %s\n' "$img" "$c" "$(docker exec "$c-control-plane" crictl images 2>/dev/null | awk -v i="${img%%:*}" '$1 ~ i {print $1 ":" $2 " (" $4 ")"; exit}')"
  done
done
say "images loaded"
