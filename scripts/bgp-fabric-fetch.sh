#!/usr/bin/env bash
# bgp-fabric-fetch.sh — put the pinned bgp-fabric tree on disk and print where.
#
#   dir=$(scripts/bgp-fabric-fetch.sh)      # everything else goes to stderr
#
# The path it prints is the only thing on stdout, so callers can capture it.
# Idempotent: a tree already at the pinned commit is left alone.
#
# BGP_FABRIC_DIR overrides the whole mechanism and points at a checkout you
# control — that is how you test a change to bgp-fabric against this lab
# BEFORE tagging it. The script says on stderr which one it used, every time,
# because a lab built against an unpinned working tree is not a lab whose
# result anyone can reproduce.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/bgp-fabric.env

if [ -n "${BGP_FABRIC_DIR:-}" ]; then
  if [ ! -d "$BGP_FABRIC_DIR/fabric" ] || [ ! -d "$BGP_FABRIC_DIR/dashboard" ]; then
    echo "bgp-fabric-fetch: BGP_FABRIC_DIR=$BGP_FABRIC_DIR is not a bgp-fabric checkout" >&2
    exit 1
  fi
  head=$(git -C "$BGP_FABRIC_DIR" rev-parse HEAD 2>/dev/null || echo "not-a-git-tree")
  dirty=""
  [ -n "$(git -C "$BGP_FABRIC_DIR" status --porcelain 2>/dev/null)" ] && dirty=" (DIRTY)"
  echo "bgp-fabric-fetch: using BGP_FABRIC_DIR=$BGP_FABRIC_DIR at ${head}${dirty}" >&2
  cd "$BGP_FABRIC_DIR" && pwd
  exit 0
fi

DEST=vendor/bgp-fabric
if [ -d "$DEST/.git" ]; then
  have=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo none)
  if [ "$have" = "$BGP_FABRIC_COMMIT" ]; then
    if [ -n "$(git -C "$DEST" status --porcelain)" ]; then
      # Editing the vendored tree loses the edit on the next pin bump and makes
      # the lab disagree with the commit it claims. Say so rather than fix it.
      echo "bgp-fabric-fetch: $DEST has local modifications." >&2
      echo "  It is a checkout of a pinned commit, not a place to edit." >&2
      echo "  Edit the bgp-fabric repo and point at it with BGP_FABRIC_DIR." >&2
      exit 1
    fi
    echo "bgp-fabric-fetch: $DEST already at $BGP_FABRIC_COMMIT ($BGP_FABRIC_TAG)" >&2
    (cd "$DEST" && pwd)
    exit 0
  fi
else
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone -q --no-checkout "$BGP_FABRIC_REPO" "$DEST"
fi

git -C "$DEST" fetch -q --tags origin
git -C "$DEST" checkout -q --detach "$BGP_FABRIC_COMMIT"
got=$(git -C "$DEST" rev-parse HEAD)
if [ "$got" != "$BGP_FABRIC_COMMIT" ]; then
  echo "bgp-fabric-fetch: checked out $got, pinned $BGP_FABRIC_COMMIT" >&2
  exit 1
fi
echo "bgp-fabric-fetch: $DEST at $BGP_FABRIC_COMMIT ($BGP_FABRIC_TAG)" >&2
(cd "$DEST" && pwd)
