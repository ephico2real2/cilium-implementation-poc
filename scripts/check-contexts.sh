#!/usr/bin/env bash
# check-contexts.sh — find kubectl contexts whose cluster no longer exists.
#
# Usage:  scripts/check-contexts.sh
#
# WHY. Deleting a cluster does not always remove its kubeconfig entry. `kind delete cluster` does,
# but a cluster removed another way -- or a kubeconfig copied between machines -- leaves a context
# behind. Using it produces a connection error that reads like a BROKEN cluster rather than a
# MISSING one, which sends you debugging the wrong thing.
#
# This does not guess. For every context it actually tries to talk to the API server, and it
# cross-checks the kind-managed ones against `kind get clusters`.
set -uo pipefail

TIMEOUT="${TIMEOUT:-5}"

echo "=== kind clusters that actually exist ==="
KIND_CLUSTERS="$(kind get clusters 2>/dev/null)"
if [ -z "$KIND_CLUSTERS" ]; then
  echo "  (none)"
else
  echo "$KIND_CLUSTERS" | sed 's/^/  /'
fi
echo

printf '%-26s %-12s %-10s %s\n' "CONTEXT" "KIND?" "REACHABLE" "VERDICT"
printf '%-26s %-12s %-10s %s\n' "-------" "-----" "---------" "-------"

stale=0
for ctx in $(kubectl config get-contexts -o name 2>/dev/null); do
  # Is this a kind context, and if so does the cluster still exist?
  kindcol="no"
  case "$ctx" in
    kind-*)
      name="${ctx#kind-}"
      if echo "$KIND_CLUSTERS" | grep -qx "$name"; then kindcol="yes"; else kindcol="MISSING"; fi
      ;;
  esac

  # Actually try to reach it -- this is the part that distinguishes stale from broken.
  if kubectl --context "$ctx" --request-timeout="${TIMEOUT}s" get --raw /version >/dev/null 2>&1; then
    reach="yes"
  else
    reach="NO"
  fi

  if [ "$kindcol" = "MISSING" ] && [ "$reach" = "NO" ]; then
    verdict="STALE — no such kind cluster; prune it"
    stale=$((stale+1))
  elif [ "$reach" = "NO" ]; then
    verdict="unreachable — cluster may be stopped, not necessarily stale"
  else
    verdict="ok"
  fi
  printf '%-26s %-12s %-10s %s\n' "$ctx" "$kindcol" "$reach" "$verdict"
done

echo
if [ "$stale" -gt 0 ]; then
  echo "$stale stale context(s). Remove with:"
  for ctx in $(kubectl config get-contexts -o name 2>/dev/null); do
    case "$ctx" in
      kind-*)
        name="${ctx#kind-}"
        echo "$KIND_CLUSTERS" | grep -qx "$name" || echo "  kubectl config delete-context $ctx"
        ;;
    esac
  done
else
  echo "No stale contexts."
fi
