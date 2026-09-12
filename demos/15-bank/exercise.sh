#!/usr/bin/env bash
# exercise.sh — drive the bank from OUTSIDE (through the Gateway) and show, per call, which cluster
# and pod handled each hop. Made to be watched, not parsed.
#
#   demos/15-bank/exercise.sh                 # 20 payments on chk-1001
#   demos/15-bank/exercise.sh 50 chk-1002     # 50 payments on another account
#   demos/15-bank/exercise.sh 60 chk-1001 --failover
#       ... and while it runs, scale poc1's payments to 0 at call 20 and back to 1 at call 40, so you
#       watch the "payments" column flip to poc2 with no failed calls.
#
# Needs: the demo 09 Gateway (bankapi.poc.local is pinned with --resolve; no /etc/hosts needed),
# docs/root-ca.crt, python3. Bash on purpose (gotcha #29).
set -uo pipefail
N="${1:-20}"; ACC="${2:-chk-1001}"; FAILOVER="${3:-}"
CTX="${CTX:-kind-poc1}"; CA="${CA:-docs/root-ca.crt}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
[ -n "$GW" ] || { echo "no Gateway address (kubectl --context $CTX -n routes get gateway routes-gw)"; exit 2; }
API="https://bankapi.poc.local"; C=(--cacert "$CA" --resolve "bankapi.poc.local:443:$GW" -s --max-time 6)
MERCHANTS=(coffee grocery fuel pharmacy books cinema bakery taxi flowers hardware)

field() { python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('-'); sys.exit()
v=d
for k in '$1'.split('.'):
    v = v.get(k, {}) if isinstance(v, dict) else {}
print(v if v not in ({}, None) else '-')"; }

bal() { curl "${C[@]}" "$API/api/balance/$ACC" | field balance_cents; }
short() { sed -E 's/^(payments|accounts|api)-[a-z0-9]+-/\1-/'; }   # pod name -> role-hash

echo "poc bank exercise — $N card payments on $ACC through $API (Gateway $GW)"
# Top up first: random amounts up to $41 × N calls must fit, or the run ends in 409 "insufficient
# funds" — a correct business decline that has nothing to do with the mesh (the first run did that).
NEED=$(( N * 4100 + 10000 )); HAVE=$(bal)
if [ "${HAVE:-0}" -lt "$NEED" ] 2>/dev/null; then
  TOP=$(( NEED - HAVE )); printf 'topping up %s by %s cents (balance %s < %s needed for %s calls): ' "$ACC" "$TOP" "$HAVE" "$NEED" "$N"
  curl "${C[@]}" -X POST "$API/api/credit/$ACC" -H 'content-type: application/json' -d "{\"amount_cents\":$TOP}" | field balance_cents | sed 's/^/balance now /'
fi
START=$(bal); echo "balance before: $START cents"
[ -n "$FAILOVER" ] && echo "failover mode: poc1 payments -> 0 replicas at call 20, back to 1 at call 40 — watch the 'payments' column"
echo
printf '%-4s %-9s %8s  %-6s %-24s %-24s %10s %7s\n' '#' merchant cents http 'payments (cluster/pod)' 'debited by (cluster/pod)' balance ms
declare -A P A; ok=0; fail=0; declined=0; spent=0; t_run=$SECONDS
for i in $(seq 1 "$N"); do
  m=${MERCHANTS[$((RANDOM % ${#MERCHANTS[@]}))]}; cents=$(( (RANDOM % 4000) + 100 ))
  if [ -n "$FAILOVER" ] && [ "$i" -eq 20 ]; then kubectl --context kind-poc1 -n bank scale deploy/payments --replicas=0 >/dev/null; echo ">>> poc1 payments scaled to 0 (sudden downtime)"; fi
  if [ -n "$FAILOVER" ] && [ "$i" -eq 40 ]; then kubectl --context kind-poc1 -n bank scale deploy/payments --replicas=1 >/dev/null; echo ">>> poc1 payments restored to 1"; fi
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  body=$(curl "${C[@]}" -w '\n%{http_code}' -X POST "$API/api/pay" -H 'content-type: application/json' -d "{\"account\":\"$ACC\",\"amount_cents\":$cents,\"merchant\":\"$m\",\"key\":\"ex-$$-$i-$RANDOM\"}")
  t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  code=$(printf '%s' "$body" | tail -1); json=$(printf '%s' "$body" | sed '$d')
  pc=$(printf '%s' "$json" | field payment.served_by.cluster); pp=$(printf '%s' "$json" | field payment.served_by.pod | short)
  dc=$(printf '%s' "$json" | field payment.upstream.served_by.cluster); dp=$(printf '%s' "$json" | field payment.upstream.served_by.pod | short)
  nb=$(printf '%s' "$json" | field payment.upstream.balance_cents)
  case "$code" in
    201) ok=$((ok+1)); spent=$((spent+cents)); P[$pc]=$(( ${P[$pc]:-0}+1 )); A[$dc]=$(( ${A[$dc]:-0}+1 ));;
    409) declined=$((declined+1)); pc="declined"; pp="insufficient funds";;   # the bank said no — not an outage
    *)   fail=$((fail+1)); pc="FAILED"; pp="http $code";;
  esac
  printf '%-4s %-9s %8s  %-6s %-24s %-24s %10s %7s\n' "$i" "$m" "$cents" "$code" "$pc/$pp" "$dc/$dp" "$nb" "$((t1-t0))"
done
END=$(bal)
echo; echo "summary"
echo "  calls: $N  ok: $ok  declined (409, insufficient funds): $declined  FAILED (infrastructure): $fail  in $((SECONDS-t_run)) s"
echo "  payments served by : $(for k in "${!P[@]}"; do printf '%s=%s ' "$k" "${P[$k]}"; done)"
echo "  debited by accounts: $(for k in "${!A[@]}"; do printf '%s=%s ' "$k" "${A[$k]}"; done)  (accounts runs in poc2 only — every debit must say poc2)"
echo "  balance before $START, after $END, spent $spent  ->  $([ $((START-END)) -eq "$spent" ] && echo 'LEDGER CONSISTENT: before - after == sum of payments' || echo "LEDGER MISMATCH: before-after=$((START-END)) vs spent=$spent")"
echo
echo "idempotency: the same key twice must debit once"
K="ex-$$-dup-$RANDOM"; b0=$(bal)
for n in 1 2; do curl "${C[@]}" -X POST "$API/api/pay" -H 'content-type: application/json' -d "{\"account\":\"$ACC\",\"amount_cents\":100,\"merchant\":\"dup-test\",\"key\":\"$K\"}" | python3 -c "import json,sys; d=json.load(sys.stdin).get('payment',{}); print('  call $n: replay=%s served by %s' % (d.get('replay', False), d.get('served_by',{}).get('cluster')))"; done
echo "  balance $b0 -> $(bal) (must differ by exactly 100)"
