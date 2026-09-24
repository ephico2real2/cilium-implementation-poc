#!/usr/bin/env bash
# bgp-fabric-images.sh — put the router-agent and dashboard images on the
# daemon, by pulling the published build or by building from source.
#
# Sourced by the up-scripts AFTER these are set:
#   FABRIC_DOCKER          array — the docker invocation, e.g. (docker --context X)
#   BGP_FABRIC             the pinned bgp-fabric tree on disk
#   REVISION / BUILT       from "$BGP_FABRIC/scripts/build-revision.sh"
#   FABRIC_ROUTER_IMAGE / FABRIC_DASHBOARD_IMAGE   the local tags compose wants
#   FRR_IMAGE
# and after `rec` exists, so every build or pull lands in the transcript.
#
# Pulling is the default because the published image IS the reviewed artefact:
# it was built by CI from the pinned commit, its OCI labels name that commit,
# and `docker inspect` can be checked against the pin. A local build of the
# same source is only *probably* the same image — the base tag may have moved
# under it, and nothing would say so.
set -uo pipefail

# The registry coordinates live with the pin. bgp-fabric-fetch.sh sources this
# file too, but it is a SUBPROCESS — nothing it sources reaches the caller, so
# this file reads the pin itself rather than assuming someone else did.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bgp-fabric.env"

# pull or build, and say which and why. Never silently fall back: a pull that
# fails and quietly builds would hide a bad pin, an unpublished commit or a
# private repository behind a green run.
fabric_image_source() {
  if [ -n "${BGP_FABRIC_DIR:-}" ]; then
    echo "bgp-fabric-images: BGP_FABRIC_DIR is set — building from that tree" >&2
    echo build
    return
  fi
  case "${REVISION:-unknown}" in
    *-dirty|unknown)
      # A dirty tree is not a commit, so no published image can correspond to
      # it. Building is the only honest answer.
      echo "bgp-fabric-images: revision is ${REVISION} — building, nothing published matches it" >&2
      echo build
      return
      ;;
  esac
  echo "${FABRIC_IMAGE_SOURCE:-pull}"
}

fabric_image_tag() {
  printf 'sha-%s\n' "$(printf '%s' "$REVISION" | cut -c1-7)"
}

# One image: pull the published tag and re-tag it to the local name compose
# asks for, or build it from the pinned source.
fabric_get_image() {
  local local_tag=$1 published=$2 context=$3 containerfile=$4
  shift 4
  local tag
  tag=$(fabric_image_tag)
  # "Present" means present FOR THIS PIN. An image left over from an earlier
  # commit carries an earlier revision label — or, if it predates the stamp,
  # none at all — and reusing it would run code the pin does not name while
  # every message said otherwise. Replace it instead of asking a person to.
  if [ "${FABRIC_REBUILD:-0}" != 1 ] && "${FABRIC_DOCKER[@]}" image inspect "$local_tag" >/dev/null 2>&1; then
    local have
    have=$("${FABRIC_DOCKER[@]}" inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$local_tag" 2>/dev/null || true)
    if [ "$have" = "$REVISION" ]; then
      rec echo "image $local_tag present at $REVISION"
      return 0
    fi
    rec echo "image $local_tag is ${have:-unlabelled}, pin is $REVISION — replacing it"
  fi
  case "$(fabric_image_source)" in
    pull)
      rec "${FABRIC_DOCKER[@]}" pull "${published}:${tag}"
      rec "${FABRIC_DOCKER[@]}" tag "${published}:${tag}" "$local_tag"
      ;;
    build)
      rec "${FABRIC_DOCKER[@]}" build -t "$local_tag" "$@" \
        --build-arg REVISION="$REVISION" --build-arg BUILT="$BUILT" \
        -f "$containerfile" "$context"
      ;;
    *)
      echo "bgp-fabric-images: FABRIC_IMAGE_SOURCE=${FABRIC_IMAGE_SOURCE:-} (want pull or build)" >&2
      return 2
      ;;
  esac
}

# The pair. The agent needs FRR_IMAGE when it is built; when it is pulled the
# base is already baked in, and its base.name label says which.
fabric_get_images() {
  fabric_get_image "$FABRIC_ROUTER_IMAGE" "$BGP_FABRIC_AGENT_IMAGE" \
    "$BGP_FABRIC/frr-agent" "$BGP_FABRIC/frr-agent/Containerfile" \
    --build-arg "FRR_IMAGE=$FRR_IMAGE" || return 1
  fabric_get_image "$FABRIC_DASHBOARD_IMAGE" "$BGP_FABRIC_DASHBOARD_IMAGE" \
    "$BGP_FABRIC/dashboard" "$BGP_FABRIC/dashboard/Containerfile" || return 1
}

# What the images claim about themselves, against the pin. A pulled image that
# names a different commit means the published tag moved; a built one that
# does is a bug in the stamp. Either way the lab must not pretend otherwise.
fabric_verify_images() {
  local img got want=$REVISION rc=0
  for img in "$FABRIC_ROUTER_IMAGE" "$FABRIC_DASHBOARD_IMAGE"; do
    got=$("${FABRIC_DOCKER[@]}" inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$img" 2>/dev/null || true)
    if [ "$got" != "$want" ]; then
      echo "bgp-fabric-images: $img is labelled revision=${got:-<none>}, pinned ${want}" >&2
      rc=1
    fi
  done
  return $rc
}
