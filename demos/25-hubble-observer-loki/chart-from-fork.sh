#!/usr/bin/env bash
# chart-from-fork.sh [branch] [commit] — install/upgrade hubble-observer from the OPERATOR'S FORK at a pinned commit,
# with the chart's own CiliumNetworkPolicy ON: that policy is what PR #9 fixes (DNS rule + the relay pod's port),
# so a Ready observer behind it is the validation of our upstream work. Helm installs from a path, not a git URL,
# so the branch is cloned into .tmp/ (git-ignored) and the commit is checked out and printed.
#   demos/25-hubble-observer-loki/chart-from-fork.sh docs/hubble-cli-image c459f3c
set -euo pipefail; cd "$(dirname "$0")/../.."
BRANCH="${1:-docs/hubble-cli-image}"; COMMIT="${2:-}"; REPO=https://github.com/ephico2real2/hubble-observer.git; DIR=.tmp/hubble-observer-fork
rm -rf "$DIR"; git clone -q --branch "$BRANCH" "$REPO" "$DIR"
[ -n "$COMMIT" ] && git -C "$DIR" checkout -q "$COMMIT"
echo "fork: $REPO  branch: $BRANCH  commit: $(git -C "$DIR" rev-parse --short HEAD) $(git -C "$DIR" log -1 --format=%s | cut -c1-60)"
(cd "$DIR/helm/hubble-observer" && helm dependency build >/dev/null 2>&1 && echo "dependencies: $(ls charts)")
helm upgrade --install hubble-observer "$DIR/helm/hubble-observer" -n hubble-observer --create-namespace --kube-context kind-poc1 \
  -f demos/25-hubble-observer-loki/values-hubble-observer.yaml --set ciliumNetworkPolicy.enabled=true --wait --timeout 5m | grep -E "REVISION|STATUS"
