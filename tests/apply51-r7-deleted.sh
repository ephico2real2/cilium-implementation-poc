#!/usr/bin/env bash
# test: the transcript must record a post-delete NotFound for probe-noproxy
# on both clusters (passes after the orchestrator re-runs apply.sh).
# usage: bash tests/apply51-r7-deleted.sh   (from repo root)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
transcript=$ROOT/demos/51-eg-kube-vip/output/transcript.txt
rc=0
for cluster in eg1 eg2; do
  if ! grep -Fq "R7 $cluster post-delete gateway/probe-noproxy: NotFound" "$transcript"; then
    echo "TEST FAIL: transcript missing R7 $cluster post-delete NotFound (needs apply.sh re-run)"
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "TEST PASS: R7 post-delete NotFound recorded for eg1 and eg2"
exit $rc
