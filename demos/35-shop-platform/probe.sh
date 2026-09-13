#!/usr/bin/env bash
# probe.sh — one request per path of the platform, from the pod that makes it in the story, with the status it saw:
# the shopper through the gateway (four backends in three namespaces), a team-to-team call, and the stranger straight
# at the shared service and at payments. wget -S prints the status line; a caller with no rule gets no answer (rc=1).
set -uo pipefail; cd "$(dirname "$0")/../.."
req() { # <namespace> <pod> <container> <url>
  local out; out=$(kubectl --context kind-poc1 -n "$1" exec "$2" -c "$3" -- sh -c "wget -S -qO- --timeout=3 '$4' 2>&1 | grep -m1 'HTTP/'; echo rc=\${PIPESTATUS:-\$?}" 2>&1 | tr '\n' ' ')
  printf '%-10s %-9s %-46s %s\n' "$1" "$2" "${4#http://}" "$out"
}
pod() { kubectl --context kind-poc1 -n "$1" get pod -l app="$2" -o jsonpath='{.items[0].metadata.name}'; }
req shop-clients shopper client http://api-gateway.shop-edge/catalog/items
req shop-clients shopper client http://api-gateway.shop-edge/orders/place
req shop-clients shopper client http://api-gateway.shop-edge/reviews/latest
req shop-clients shopper client http://api-gateway.shop-edge/pay/charge
req shop-merchant "$(pod shop-merchant merchant)" caller http://catalog.shop-core/items
req shop-reviews ratings client http://reviews.shop-reviews/stars
req shop-clients stranger client http://catalog.shop-core/items
req shop-clients stranger client http://payment-gateway.shop-payments/charge
req shop-clients shopper client http://catalog.shop-core/items
