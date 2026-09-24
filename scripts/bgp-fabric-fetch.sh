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
# `cd` echoes the directory it landed on when the match came from CDPATH, and
# that line would arrive on stdout beside the path the caller captures.
unset CDPATH
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

# Refuse an edited tree and say where to edit instead. `-d $DEST/dashboard`
# guards the fast path against a run killed between the clone and the
# checkout: `git clone --no-checkout` leaves an index in which every file
# reads as deleted, and a bare cleanliness test would call that an edit and
# never recover.
refuse_if_edited() { # where — the sha the tree claims, for the message
  [ -n "$(git -C "$DEST" status --porcelain)" ] || return 0
  echo "bgp-fabric-fetch: $DEST has local modifications (tree is at $1)." >&2
  echo "  It is a checkout of a pinned commit, not a place to edit." >&2
  echo "  Edit the bgp-fabric repo and point at it with BGP_FABRIC_DIR," >&2
  echo "  or discard the edit with: rm -rf $DEST" >&2
  exit 1
}

if [ -d "$DEST/.git" ]; then
  have=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo none)
  if [ "$have" = "$BGP_FABRIC_COMMIT" ] && [ -d "$DEST/dashboard" ]; then
    refuse_if_edited "$have"
    echo "bgp-fabric-fetch: $DEST already at $BGP_FABRIC_COMMIT ($BGP_FABRIC_TAG)" >&2
    (cd "$DEST" && pwd)
    exit 0
  fi
  # The remote URL is read from .git/config, written once at clone time: a
  # repository that has moved in bgp-fabric.env would otherwise keep fetching
  # from the old one while this script reports the new one.
  git -C "$DEST" remote set-url origin "$BGP_FABRIC_REPO"
else
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone -q --no-checkout "$BGP_FABRIC_REPO" "$DEST"
fi

# --force, because a tag MOVED upstream makes a plain `fetch --tags` exit 1
# and `-q` swallows the reason: the lab would then die with no output at all,
# over a tag the pin does not even use. Every git call here says what failed —
# `set -e` alone aborts silently, and silence is what the pin is meant to end.
if ! git -C "$DEST" fetch -q --force --tags origin; then
  echo "bgp-fabric-fetch: cannot fetch $BGP_FABRIC_REPO into $DEST" >&2
  exit 1
fi
if ! git -C "$DEST" checkout -q --detach "$BGP_FABRIC_COMMIT"; then
  echo "bgp-fabric-fetch: cannot check out $BGP_FABRIC_COMMIT — force-pushed away," >&2
  echo "  or a local edit is in the way. $DEST is a checkout, not a workspace." >&2
  exit 1
fi
got=$(git -C "$DEST" rev-parse HEAD)
if [ "$got" != "$BGP_FABRIC_COMMIT" ]; then
  echo "bgp-fabric-fetch: checked out $got, pinned $BGP_FABRIC_COMMIT" >&2
  exit 1
fi
# AFTER the checkout, not only before it: `git checkout` carries a modified
# file across whenever the two commits hold it identically, and carries every
# untracked file across unconditionally. The tree would then sit at the
# pinned sha holding code that is not the pinned code — the one outcome a pin
# exists to make impossible.
refuse_if_edited "$BGP_FABRIC_COMMIT"
echo "bgp-fabric-fetch: $DEST at $BGP_FABRIC_COMMIT ($BGP_FABRIC_TAG)" >&2
(cd "$DEST" && pwd)
