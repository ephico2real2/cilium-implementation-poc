#!/usr/bin/env bash
# hubble-tls.sh — the relays require mutual TLS (day-one values since 2026-09-12; demo 25 Part 5, gotcha #75).
#
#   scripts/hubble-tls.sh <kube-context>                  print the CLI flags for one call (what the scripts use)
#   scripts/hubble-tls.sh --configure <ctx> [<ctx>...]    write the same into the hubble CLI's own config file ONCE,
#                                                         so every `hubble …` command in this repo works as written
#
# Which certificate: the operator certificate hubble-cli-client-certs (cert-manager, demo 25 Part 5e) when it exists;
# before cert-manager (a fresh build at Step 5) the chart's Helm-method hubble-relay-client-certs, signed by that
# cluster's own cilium-ca — the relay verifies clients against its CA only. With --configure, every listed context's
# CA is added (before demo 08/24 each cluster has its own CA; after, they are one root) and the first's client cert is
# used. Files land in .tmp/hubble-tls/<context>/ (git-ignored, 0600). The CLI's precedence is flag > env > config file.
set -euo pipefail; cd "$(dirname "$0")/.."
fetch() { # <ctx> → dir
  local ctx="$1" dir=".tmp/hubble-tls/$1" sec
  mkdir -p "$dir"; chmod 700 "$dir"
  if kubectl --context "$ctx" -n kube-system get secret hubble-cli-client-certs >/dev/null 2>&1; then sec=hubble-cli-client-certs; else sec=hubble-relay-client-certs; fi
  for k in ca.crt tls.crt tls.key; do kubectl --context "$ctx" -n kube-system get secret "$sec" -o jsonpath="{.data.$(echo $k | sed 's/\./\\./')}" | base64 -d > "$dir/$k"; chmod 600 "$dir/$k"; done
  echo "$sec" > "$dir/source"; echo "$dir"
}
SN=cli.hubble-relay.cilium.io   # the relay's certificate is *.hubble-relay.cilium.io: any name under it verifies
if [ "${1:-}" = "--configure" ]; then
  shift; [ $# -ge 1 ] || { echo "usage: $0 --configure <kube-context> [<kube-context>...]" >&2; exit 2; }
  CAS=""; FIRST=""
  for ctx in "$@"; do d=$(fetch "$ctx"); CAS="${CAS:+$CAS,}$PWD/$d/ca.crt"; [ -z "$FIRST" ] && FIRST="$PWD/$d"; done
  hubble config set tls true; hubble config set tls-server-name "$SN"; hubble config set tls-ca-cert-files "$CAS"
  hubble config set tls-client-cert-file "$FIRST/tls.crt"; hubble config set tls-client-key-file "$FIRST/tls.key"
  echo "hubble CLI configured ($(hubble config get 2>/dev/null | grep -c '^tls') tls keys in $(hubble config view 2>/dev/null | grep -m1 -o 'config-file.*' || echo '~/.config/hubble/config.yaml')): client cert from $(cat "$FIRST/source") of $1; CAs of: $*"
  exit 0
fi
CTX="${1:?kube-context}"; d=$(fetch "$CTX")
echo "--tls --tls-server-name $SN --tls-ca-cert-files $d/ca.crt --tls-client-cert-file $d/tls.crt --tls-client-key-file $d/tls.key"
