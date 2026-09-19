#!/usr/bin/env bash
# test: demo 51's docs carry the review's findings and the measured composition of the
# VIP move's gap (kube-vip's log window, externalTrafficPolicy: Local), and the GUIDE
# quotes the error a reader will actually see in exercise 3.
# usage: bash tests/docs51-review-and-gap.sh demos/51-eg-kube-vip   (exit 0 = test passes)
set -uo pipefail
D=${1:?demo dir}; rc=0
chk() { grep -qF -- "$2" "$D/$1" || { echo "TEST FAIL: $1 lacks: $2"; rc=1; }; }
grep -q 'review has not run' "$D/RECAP.md" && { echo "TEST FAIL: RECAP still says the review has not run"; rc=1; }
chk RECAP.md '**What the review caught.** OB3'
chk RECAP.md '10.837 s'
chk RECAP.md 'externalTrafficPolicy:'
chk RECAP.md 'openssl s_client'
chk README.md 'successful add IP'
chk README.md '10.909 s'
chk README.md 'leader.go:102'
chk GUIDE.md 'server does not
support the reflection API'
[ $rc -eq 0 ] && echo "TEST PASS: docs carry the review and the gap's composition"
exit $rc
