#!/usr/bin/env bash
# test: demo 51's docs carry the review's findings and the measured composition of the
# VIP move's gap (kube-vip's log window, externalTrafficPolicy: Local), and the GUIDE
# quotes the error a reader will actually see in exercise 3.
# usage: bash tests/docs51-review-and-gap.sh demos/51-eg-kube-vip   (exit 0 = test passes)
set -uo pipefail
D=${1:?demo dir}; rc=0
chk() { grep -qF -- "$2" "$D/$1" || { echo "TEST FAIL: $1 lacks: $2"; rc=1; }; }
grep -q 'review has not run' "$D/RECAP.md" && { echo "TEST FAIL: RECAP still says the review has not run"; rc=1; }
# the demo-guide format (2026-09-19): the review lives in docs/REVIEW_DEMO51.md, the guide links it;
# the gap's composition is in the guide and the record, the reflection error in the exercises
chk RECAP.md 'REVIEW_DEMO51'
chk RECAP.md '10.837'
chk RECAP.md 'externalTrafficPolicy'
chk README.md 'successful add IP'
chk README.md '10.909'
chk README.md 'leader.go'
grep -q 'reflection API' "$D/GUIDE.md" || { echo "TEST FAIL: GUIDE.md lacks the recorded reflection error"; rc=1; }
grep -q '**What the review caught.** OB3' docs/REVIEW_DEMO51.md 2>/dev/null; grep -q 'OB3' docs/REVIEW_DEMO51.md || { echo "TEST FAIL: docs/REVIEW_DEMO51.md missing"; rc=1; }
[ $rc -eq 0 ] && echo "TEST PASS: docs carry the review and the gap's composition"
exit $rc
