#!/usr/bin/env bash
# test: HTTPS probes must not disable CA verification with -k, and the transcript
# must record openssl s_client for all six SAN names.
# usage: bash tests/apply51-tls-leaf.sh   (from repo root; exit 0 = test passes)
# The script half is decided by this round; the transcript half passes only
# after the orchestrator re-runs apply.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
apply=demos/51-eg-kube-vip/apply.sh
check=demos/51-eg-kube-vip/check.sh
transcript=demos/51-eg-kube-vip/output/transcript.txt
script_ok=1
transcript_ok=1

if grep -nE 'curl -sk|"-sk"' "$apply" "$check"; then
  echo "TEST FAIL: script half — insecure HTTPS probe remains (-sk)"
  script_ok=0
fi

while read -r host addr; do
  if ! grep -Fq "TLS leaf $host @ $addr: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=$host" \
      "$transcript"; then
    echo "TEST FAIL: transcript half — missing TLS leaf $host @ $addr (needs apply.sh re-run)"
    transcript_ok=0
  fi
done <<'EOF'
api.eg1.poc.local 172.19.255.240
grpc.eg1.poc.local 172.19.255.240
api.eg2.poc.local 172.19.255.176
grpc.eg2.poc.local 172.19.255.176
api.eg.poc.local 172.19.255.16
grpc.eg.poc.local 172.19.255.16
EOF

if [ "$script_ok" -eq 1 ] && [ "$transcript_ok" -eq 1 ]; then
  echo "TEST PASS: no -sk in apply.sh/check.sh; six TLS leaf verify=ok lines in the transcript"
  exit 0
fi
if [ "$script_ok" -eq 1 ]; then
  echo "TEST FAIL: transcript half (script half passed — no -sk)"
  exit 1
fi
if [ "$transcript_ok" -eq 1 ]; then
  echo "TEST FAIL: script half (transcript half passed)"
  exit 1
fi
echo "TEST FAIL: both halves"
exit 1
