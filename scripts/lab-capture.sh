#!/usr/bin/env bash
# lab-capture.sh [out-dir] [spec] — the lab's pages as PNGs with an evidence line each, driven by a YAML spec of pages
# (scripts/capture/lab.yaml: Grafana's dashboards, the Hubble UI, cf2cnp) through scripts/capture/walk.js, the pages'
# expectations measured (exit 2 when a page fails one). On a Mac or a
# Linux host: Playwright is installed into .tmp/pw once (git-ignored, pinned); in CI the same walker runs through the
# composite action .github/actions/browser-walk with the install cached. Chromium resolves *.poc.local itself, from the
# Gateway address read here — no /etc/hosts.
set -euo pipefail; cd "$(dirname "$0")/.."
OUT="${1:-captures}"; SPEC="${2:-scripts/capture/lab.yaml}"; mkdir -p "$OUT"; CTX="${LAB_STACK_CTX:-kind-poc1}"; PW_VERSION="${PW_VERSION:-1.63.0}"; JS_YAML_VERSION="${JS_YAML_VERSION:-4.1.0}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
HUBBLE=$(kubectl --context "$CTX" -n kube-system get svc hubble-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$GW" ] || { echo "::error::routes-gw has no address (scripts/lab-stack.sh routes)"; exit 1; }
if [ ! -d .tmp/pw/node_modules/playwright ] || [ ! -d .tmp/pw/node_modules/js-yaml ]; then
  mkdir -p .tmp/pw && (cd .tmp/pw && npm init -y >/dev/null && npm i --no-audit --no-fund "playwright@$PW_VERSION" "js-yaml@$JS_YAML_VERSION" >/dev/null && npx playwright install --with-deps chromium >/dev/null 2>&1) || { echo "::error::Playwright $PW_VERSION did not install"; exit 1; }
fi
echo "capturing to $OUT from $SPEC: Grafana via $GW, Hubble UI at ${HUBBLE:-$GW}, Playwright $PW_VERSION"
HUBBLE_ADDR="${HUBBLE:-$GW}"
S="$OUT" GW="$GW" HUBBLE="$HUBBLE_ADDR" GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-poc-grafana}" NODE_PATH="$PWD/.tmp/pw/node_modules" node scripts/capture/walk.js "$SPEC" | tee "$OUT/walk.log"
