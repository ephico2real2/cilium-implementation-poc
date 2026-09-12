#!/usr/bin/env bash
# check.sh — prove the bank works ACROSS the mesh, then prove failover, with every response's
# served_by shown. Bash on purpose (gotcha #29). Run: scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/check.sh
set -uo pipefail
k1() { kubectl --context kind-poc1 "$@"; }; k2() { kubectl --context kind-poc2 "$@"; }
CLIENT=$(k1 -n forensic get pod client -o jsonpath='{.metadata.name}' 2>/dev/null)   # netshoot with curl + jq, from demo 11
[ -n "$CLIENT" ] || { echo "needs the demo 11 rig's client pod in poc1/forensic (curl + jq)"; exit 2; }
c1() { k1 -n forensic exec "$CLIENT" -- "$@"; }
# curl | jq inside ONE exec — `kubectl exec … | kubectl exec … jq` gives jq no stdin (the first run printed nothing).
q() { k1 -n forensic exec "$CLIENT" -- sh -c "$1"; }
hdr() { echo; echo "== $*"; }
API=http://api.bank.svc.cluster.local; ACC=chk-1001

hdr "0. readiness and the merged service maps (both clusters must list BOTH payments backends)"
for c in poc1 poc2; do printf '  %s not-ready pods: %s\n' $c "$(kubectl --context kind-$c -n bank get pods --no-headers | awk '$2!="1/1"' | wc -l | tr -d ' ')"; done
P1=$(k1 -n bank get svc payments -o jsonpath='{.spec.clusterIP}'); P2=$(k2 -n bank get svc payments -o jsonpath='{.spec.clusterIP}')
for i in $(seq 1 24); do n1=$(k1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A3 "$P1:80" | grep -c '=>'); n2=$(k2 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A3 "$P2:80" | grep -c '=>'); [ "$n1" -ge 2 ] && [ "$n2" -ge 2 ] && break; sleep 5; done
echo "  payments backends known: poc1=$n1 poc2=$n2 (after ~$((i*5))s)"
k1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A3 "$P1:80" | sed 's/^/    poc1: /'

hdr "1. the whole path in one response: web's api -> accounts (must be poc2) and -> payments"
q "curl -s $API/api/statement/$ACC | jq -c '{api: .served_by.cluster, accounts: .balance.served_by.cluster, accounts_pod: .balance.served_by.pod, balance_cents: .balance.balance_cents, payments: .statement.served_by.cluster}'"

hdr "2. a card payment: api(poc1) -> payments(either) -> accounts(poc2) -> postgres; then the SAME key again = idempotent replay, no second debit"
KEY="chk-$(date +%s)"
PAY="curl -s -X POST $API/api/pay -H content-type:application/json -d '{\"account\":\"$ACC\",\"amount_cents\":1250,\"merchant\":\"coffee\",\"key\":\"$KEY\"}'"
q "$PAY | jq -c '{balance_after: .payment.upstream.balance_cents, payments_cluster: .payment.served_by.cluster, debited_by: .payment.upstream.served_by.cluster, debited_pod: .payment.upstream.served_by.pod, replay: .payment.replay}'"
q "$PAY | jq -c '{replay: .payment.replay, payments_cluster: .payment.served_by.cluster}'"
q "curl -s $API/api/balance/$ACC | jq -c '{balance_cents_after_ONE_debit: .balance_cents, answered_by: .upstream.served_by.cluster}'"

hdr "3. ACTIVE-ACTIVE: 40 payments through the global service — which cluster served each"
q 'for i in $(seq 1 40); do curl -s -X POST '"$API"'/api/pay -H content-type:application/json -d "{\"account\":\"chk-1002\",\"amount_cents\":100,\"merchant\":\"aa-$i\",\"key\":\"aa-$RANDOM-$i\"}" | jq -r ".payment.served_by.cluster // \"FAIL\""; done | sort | uniq -c' | sed 's/^/  /'

hdr "4. FAILOVER A (default affinity): continuous traffic; at t=15s poc1's payments is scaled to 0 (sudden downtime); at t=40s restored"
c1 bash -c 'end=$((SECONDS+60)); ok=0; fail=0; declare -A by; while [ $SECONDS -lt $end ]; do r=$(curl -s --max-time 2 -X POST '"$API"'/api/pay -H "content-type: application/json" -d "{\"account\":\"chk-1002\",\"amount_cents\":1,\"merchant\":\"fo\",\"key\":\"fo-$RANDOM-$SECONDS-$RANDOM\"}" | jq -r ".payment.served_by.cluster // empty"); if [ -n "$r" ]; then ok=$((ok+1)); by[$r]=$(( ${by[$r]:-0} + 1 )); else fail=$((fail+1)); fi; if [ $((SECONDS % 5)) -eq 0 ] && [ -z "${p:-}" ]; then echo "  t=${SECONDS}s ok=$ok fail=$fail poc1=${by[poc1]:-0} poc2=${by[poc2]:-0}"; p=1; elif [ $((SECONDS % 5)) -ne 0 ]; then p=; fi; sleep 0.2; done; echo "  TOTAL ok=$ok fail=$fail poc1=${by[poc1]:-0} poc2=${by[poc2]:-0}"' &
LOOP=$!; sleep 15; echo "  >>> $(date -u +%T) scaling poc1 payments to 0"; k1 -n bank scale deploy/payments --replicas=0 >/dev/null; sleep 25; echo "  >>> $(date -u +%T) restoring poc1 payments to 1"; k1 -n bank scale deploy/payments --replicas=1 >/dev/null; wait $LOOP
k1 -n bank rollout status deploy/payments --timeout=120s 2>&1 | tail -1

hdr "5. FAILOVER B (affinity: local): prefer local, use remote only when no local backend is healthy"
for c in poc1 poc2; do kubectl --context kind-$c -n bank annotate svc payments service.cilium.io/affinity=local --overwrite >/dev/null; done; sleep 5
echo "  with local healthy, 20 requests:"; q 'for i in $(seq 1 20); do curl -s -X POST '"$API"'/api/pay -H content-type:application/json -d "{\"account\":\"chk-1002\",\"amount_cents\":1,\"merchant\":\"aff\",\"key\":\"aff-$RANDOM-$i\"}" | jq -r ".payment.served_by.cluster // \"FAIL\""; done | sort | uniq -c' | sed 's/^/    /'
k1 -n bank scale deploy/payments --replicas=0 >/dev/null; sleep 8
echo "  local scaled to 0, 20 requests:"; q 'for i in $(seq 1 20); do curl -s --max-time 3 -X POST '"$API"'/api/pay -H content-type:application/json -d "{\"account\":\"chk-1002\",\"amount_cents\":1,\"merchant\":\"aff\",\"key\":\"aff2-$RANDOM-$i\"}" | jq -r ".payment.served_by.cluster // \"FAIL\""; done | sort | uniq -c' | sed 's/^/    /'
k1 -n bank scale deploy/payments --replicas=1 >/dev/null; for c in poc1 poc2; do kubectl --context kind-$c -n bank annotate svc payments service.cilium.io/affinity- >/dev/null; done; k1 -n bank rollout status deploy/payments --timeout=120s 2>&1 | tail -1

hdr "6. the poc2 side: payments there reaches redis (poc1) and accounts (poc2) — a throwaway curl pod in poc2"
k2 delete pod bankprobe --wait=true >/dev/null 2>&1   # a stale one from an interrupted run blocks `kubectl run`
k2 run bankprobe --rm -i --restart=Never --image=curlimages/curl:8.14.1 --command -- sh -c 'curl -s -X POST http://payments.bank.svc.cluster.local/payments -H "content-type: application/json" -d "{\"account\":\"chk-1002\",\"amount_cents\":5,\"merchant\":\"from-poc2\",\"key\":\"p2-'$RANDOM'\"}"' 2>/dev/null | python3 -c 'import json,sys; d=json.loads([l for l in sys.stdin if l.startswith("{")][0]); print("  ", {"payments_cluster": d["served_by"]["cluster"], "debited_by": d["upstream"]["served_by"]["cluster"], "stored_in_redis_via_mesh": "key" in d})'

hdr "7. the page through the Gateway (bank.poc.local on the wildcard cert)"
GW=$(k1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
curl -s --cacert docs/root-ca.crt --resolve "bank.poc.local:443:$GW" https://bank.poc.local/ -o /tmp/bank.html -w "  https://bank.poc.local -> http %{http_code}\n"; grep -o '<p class="path">.*</p>' /tmp/bank.html | sed 's/<[^>]*>//g; s/^/  /'
echo; echo "balance now: $(q "curl -s $API/api/balance/chk-1002 | jq -r .balance_cents") cents on chk-1002 (started at 120000)"
