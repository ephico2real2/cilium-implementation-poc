#!/usr/bin/env bash
# lab-capture.sh [out-dir] — the lab's pages as PNGs with an evidence line each (Grafana's dashboards, the Hubble UI,
# cf2cnp), with Playwright pinned the way demo 16's browser checks pinned it. Needs node; installs Playwright and
# Chromium into .tmp/pw once (git-ignored). Reads the Gateway and Hubble UI addresses from the cluster.
set -euo pipefail; cd "$(dirname "$0")/.."
OUT="${1:-captures}"; mkdir -p "$OUT"; CTX="${LAB_STACK_CTX:-kind-poc1}"; PW_VERSION="${PW_VERSION:-1.63.0}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
HUBBLE=$(kubectl --context "$CTX" -n kube-system get svc hubble-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$GW" ] || { echo "::error::routes-gw has no address (scripts/lab-stack.sh routes)"; exit 1; }
if [ ! -d .tmp/pw/node_modules/playwright ]; then
  mkdir -p .tmp/pw && (cd .tmp/pw && npm init -y >/dev/null && npm i --no-audit --no-fund "playwright@$PW_VERSION" >/dev/null && npx playwright install --with-deps chromium >/dev/null 2>&1) || { echo "::error::Playwright $PW_VERSION did not install"; exit 1; }
fi
echo "capturing to $OUT: Grafana via $GW, Hubble UI at ${HUBBLE:-no address}, Playwright $PW_VERSION"
HUBBLE_ADDR="${HUBBLE:-$GW}"
S="$OUT" GW="$GW" HUBBLE="$HUBBLE_ADDR" NODE_PATH="$PWD/.tmp/pw/node_modules" node scripts/capture/dashboards.js
ls -la "$OUT"/*.png | awk '{print "  " $5, $9}'
