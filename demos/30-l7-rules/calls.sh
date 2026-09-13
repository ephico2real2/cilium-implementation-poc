#!/usr/bin/env bash
# calls.sh — one request per case, from the pod the policy names (or does not), with the HTTP status the caller saw.
# wget -S prints the status line; a caller with no L3/L4 rule gets no answer at all (timeout, rc=1).
set -uo pipefail; cd "$(dirname "$0")/../.."; NS=cf2cnp-lab30
req() { # <pod> <container> <url>
  local out; out=$(kubectl --context kind-poc1 -n $NS exec "$1" -c "$2" -- sh -c "wget -S -qO- --timeout=3 '$3' 2>&1 | grep -m1 'HTTP/'; echo rc=\${PIPESTATUS:-\$?}" 2>&1 | tr '\n' ' ')
  printf '%-10s %-45s %s\n' "$1" "${3#http://}" "$out"
}
req pos client http://shop-frontend.$NS/
req pos client http://shop-frontend.$NS/checkout
req pos client "http://shop-frontend.$NS/checkout?promo=1"
req pos client http://shop-frontend.$NS/admin
req "$(kubectl --context kind-poc1 -n $NS get pod -l app=shop-frontend -o jsonpath='{.items[0].metadata.name}')" caller "http://shop-backend.$NS/api/orders?id=7"
req "$(kubectl --context kind-poc1 -n $NS get pod -l app=shop-frontend -o jsonpath='{.items[0].metadata.name}')" caller http://shop-backend.$NS/admin
req stranger client http://shop-frontend.$NS/
req stranger client http://shop-backend.$NS/api/orders
