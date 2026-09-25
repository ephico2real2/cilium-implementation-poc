#!/usr/bin/env bash
# test: scripts/demo46-colima-e2e.sh names compose's real reconcile rule once,
# and does not also carry the refuted one.
#
# Two comments in step 4 contradicted each other: one said a base-file `up`
# "reconciles a container to the spec it is given, so an overlay attached
# beforehand is removed again"; the next said compose "does NOT remove an
# extra network". Measured on compose v5.5.1 (a throwaway project, same
# daemon): an ADDITIONAL network leaves the container alone (same id, network
# kept); a MISSING expected network recreates it; --no-recreate does neither.
# The first comment was the mechanism the commit message had already retracted.
#
# The step-4 comment is joined into one line before matching: its sentences
# wrap, and a line grep for a wrapped phrase finds nothing either way.
#   usage: bash tests/demo46-colima-e2e-comment.sh   (no lab needed)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
f="$R/scripts/demo46-colima-e2e.sh"
step4=$(sed -n '/^  # AFTER apply/,/^  echo "== 4\./p' "$f" | sed 's/^ *# *//' | tr '\n' ' ' | tr -s ' ')
[ -n "$step4" ] || { echo "TEST FAIL: no step-4 comment block (\"# AFTER apply\" … echo \"== 4.\") in $f"; exit 1; }
if printf '%s' "$step4" | grep -qE 'attached beforehand is removed again|reconciles a container to the spec it is given'; then
  echo "TEST FAIL: the refuted mechanism (an extra network is removed) is still in the step-4 comment"
  exit 1
fi
printf '%s' "$step4" | grep -q 'never on an additional one' \
  || { echo "TEST FAIL: the measured rule (never on an additional network) is not in the step-4 comment"; exit 1; }
printf '%s' "$step4" | grep -q 'as long as nothing else about the service changed' \
  || { echo "TEST FAIL: the rule's own condition (config hash and image unchanged) is not in the step-4 comment"; exit 1; }
echo "TEST PASS: one mechanism in the step-4 comment, the measured one, with its condition"
