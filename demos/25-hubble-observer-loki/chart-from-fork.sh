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
# Helm resolves a dependency's `repository:` URL only through a repository ADDED BY NAME: on a host without them,
# `helm dependency build` stops with "no repository definition for https://… Please add the missing repos via 'helm
# repo add'" (Helm 3.14; the runner, run 34889840964; reproduced with an empty repositories.yaml) — the laptop had them
for r in cf2cnp hubble-policy-verdicts; do helm repo add "$r" "https://ephico2real2.github.io/$r" >/dev/null 2>&1 || true; done
(cd "$DIR/helm/hubble-observer" && helm dependency build 2>&1 | grep -vE '^(Update Complete|Saving|Downloading|Deleting)' ; echo "dependencies: $(ls charts)")
helm upgrade --install hubble-observer "$DIR/helm/hubble-observer" -n hubble-observer --create-namespace --kube-context kind-poc1 \
  -f demos/25-hubble-observer-loki/values-hubble-observer.yaml --set ciliumNetworkPolicy.enabled=true --wait --timeout 5m | grep -E "REVISION|STATUS"
