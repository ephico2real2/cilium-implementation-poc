#!/usr/bin/env bash
# test: syntax and node --test for the bgp-fabric dashboard UI helpers.
# usage: bash tests/dashboard-ui-unit.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R/demos/46-bgp-fabric/dashboard/static"
node --check ui.js
node --check app.js
node --test ui.test.js
echo "TEST PASS: dashboard ui.js + app.js syntax and unit tests"
