#!/usr/bin/env bash
# dbfailover.sh — the database test cases for demo 15 Part 8, in order, each judged by data:
#   1. replication is live and CROSS-CLUSTER: pg_stat_replication on the poc2 primary, a write on poc2 visible on poc1
#   2. the primary POD dies: reads keep working from the poc1 standby ("db":"standby"), writes pause, then all resumes
#   3. the primary is LOST (scaled to 0): promote the poc1 standby, repoint accounts, payments resume on poc1's database
#   4. failback: rebuild poc2 from poc1 as a standby, promote poc2, rebuild poc1 as standby -> original topology
# Bash on purpose. Run: scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/dbfailover.sh
set -uo pipefail
FROM="${FROM:-1}"                      # FROM=3 re-runs only the promotion + failback cases
run() { [ "$1" -ge "$FROM" ]; }
k1() { kubectl --context kind-poc1 "$@"; }; k2() { kubectl --context kind-poc2 "$@"; }
CA="${CA:-docs/root-ca.crt}"; GW=$(k1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
API="https://bankapi.poc.local"; C=(--cacert "$CA" --resolve "bankapi.poc.local:443:$GW" -s --max-time 5)
PRIMARY_DSN="postgres://bank:bank@postgres-primary.bank.svc.cluster.local:5432/bank?sslmode=disable"
STANDBY_DSN="postgres://bank:bank@postgres-standby.bank.svc.cluster.local:5432/bank?sslmode=disable"
hdr() { echo; echo "== $*"; }
field() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print('-'); sys.exit()
v=d
for k in '$1'.split('.'): v = v.get(k, {}) if isinstance(v, dict) else {}
print(v if v not in ({}, None) else '-')"; }
bal() { curl "${C[@]}" "$API/api/balance/$1" | field balance_cents; }
baldb() { curl "${C[@]}" "$API/api/balance/$1" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d["balance_cents"], "from", d["upstream"].get("db","?"))
except Exception: print("ERROR")'; }
pay() { curl "${C[@]}" -o /dev/null -w '%{http_code}' -X POST "$API/api/pay" -H 'content-type: application/json' -d "{\"account\":\"$1\",\"amount_cents\":$2,\"merchant\":\"$3\",\"key\":\"db-$$-$RANDOM-$RANDOM\"}"; }
psql1() { k1 -n bank exec postgres-standby-0 -c postgres -- psql -U bank -d bank -Atc "$1" 2>/dev/null; }
psql2() { k2 -n bank exec postgres-0 -c postgres -- psql -U bank -d bank -Atc "$1" 2>/dev/null; }
wait_ready() { local kf=$1 pod=$2 old=$3 i; for i in $(seq 1 90); do u=$($kf -n bank get pod "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null); r=$($kf -n bank get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null); [ -n "$u" ] && [ "$u" != "$old" ] && [ "$r" = true ] && { echo $((i*2)); return; }; sleep 2; done; echo timeout; }
# a reader/writer loop for $1 seconds: balance read + a 1-cent payment each second; prints counts and the longest write outage
loop() { local secs=$1; local rok=0 rfail=0 wok=0 wfail=0 gap=0 maxgap=0 sb=0; local end=$((SECONDS+secs)); while [ $SECONDS -lt $end ]; do
  out=$(baldb chk-1001); case "$out" in ERROR) rfail=$((rfail+1));; *standby) rok=$((rok+1)); sb=$((sb+1));; *) rok=$((rok+1));; esac
  if [ "$(pay chk-1001 1 loop)" = 201 ]; then wok=$((wok+1)); [ $gap -gt $maxgap ] && maxgap=$gap; gap=0; else wfail=$((wfail+1)); gap=$((gap+1)); fi; sleep 1; done
  [ $gap -gt $maxgap ] && maxgap=$gap; echo "  loop ${secs}s: reads ok=$rok (from standby: $sb) failed=$rfail | writes ok=$wok failed=$wfail longest write outage ${maxgap}s"; }

run 1 && {
hdr "1. replication is live, and it crosses the mesh"
echo "  primary (poc2) pg_stat_replication:"; psql2 "SELECT client_addr||' state='||state||' sync='||sync_state||' replay_lag='||coalesce(replay_lag::text,'0') FROM pg_stat_replication" | sed 's/^/    /'
echo "  standby (poc1) pg_stat_wal_receiver:"; psql1 "SELECT 'in_recovery='||pg_is_in_recovery()||' status='||status||' sender='||sender_host||' written='||written_lsn||' flushed='||flushed_lsn FROM pg_stat_wal_receiver" | sed 's/^/    /'
echo "  the standby's client address is a poc1 pod: $(k1 -n bank get pod postgres-standby-0 -o jsonpath='{.status.podIP}') — the WAL stream is pod-to-pod across the mesh"
B=$(bal chk-1001); echo "  write on poc2 (a \$0.77 payment) …"; pay chk-1001 77 replication-test >/dev/null; sleep 1
echo "  primary says chk-1001 = $(psql2 "SELECT balance_cents FROM accounts WHERE id='chk-1001'")   standby says chk-1001 = $(psql1 "SELECT balance_cents FROM accounts WHERE id='chk-1001'")   (was $B; both must be $((B-77)))"
echo "  standby refuses writes (it is read-only until promoted): $(psql1 "UPDATE accounts SET balance_cents=balance_cents WHERE id='chk-1001'" 2>&1 | head -1; k1 -n bank exec postgres-standby-0 -c postgres -- psql -U bank -d bank -Atc "UPDATE accounts SET balance_cents=balance_cents WHERE id='chk-1001'" 2>&1 | head -1)"

}
run 2 && {
hdr "2. the primary POD dies — reads continue from the standby, writes pause briefly"
OLD=$(k2 -n bank get pod postgres-0 -o jsonpath='{.metadata.uid}')
loop 45 & L=$!; sleep 8; echo "  >>> $(date -u +%T) deleting postgres-0 (poc2 primary)"; k2 -n bank delete pod postgres-0 --wait=false >/dev/null
T=$(wait_ready k2 postgres-0 "$OLD"); echo "  >>> $(date -u +%T) new primary pod Ready ~${T}s later"; wait $L
echo "  replication resumed? primary sees: $(psql2 "SELECT count(*)||' standby(s) state='||coalesce(max(state),'none') FROM pg_stat_replication")"

}
run 3 && {
hdr "3. the primary is LOST (scaled to 0) — promote the poc1 standby, repoint accounts, payments resume on poc1's database"
echo "  balance before: $(baldb chk-1001)"; k2 -n bank scale sts/postgres --replicas=0 >/dev/null; sleep 6
echo "  with the primary gone: read -> $(baldb chk-1001); a payment -> http $(pay chk-1001 5 during-outage)   (reads served by the standby, writes refused: expected)"
echo "  >>> promoting the standby: SELECT pg_promote()"; psql1 "SELECT pg_promote(true, 30)" | sed 's/^/    pg_promote returned /'; sleep 3
echo "  standby now: in_recovery=$(psql1 'SELECT pg_is_in_recovery()')  timeline=$(psql1 'SELECT timeline_id FROM pg_control_checkpoint()')"
echo "  >>> repointing accounts: PG_DSN -> the poc1 database (one env change, one rollout)"
k2 -n bank set env deploy/accounts PG_DSN="$STANDBY_DSN" >/dev/null; k2 -n bank rollout status deploy/accounts --timeout=180s 2>&1 | tail -1 | sed 's/^/    /'
echo "  payments now (accounts in poc2 writing to the promoted database in poc1, through the mesh): 20 in a row, counted"
ok=0; bad=0; for i in $(seq 1 20); do c=$(pay chk-1001 100 after-promotion); [ "$c" = 201 ] && ok=$((ok+1)) || { bad=$((bad+1)); echo "    #$i -> http $c"; }; done; echo "    20 payments: $ok ok, $bad failed; balance $(baldb chk-1001)"
echo "  ledger on the promoted database: $(psql1 "SELECT id||'='||balance_cents FROM accounts ORDER BY id" | tr '\n' ' ')"

}
run 4 && {
hdr "4. failback to the original topology (a rebuild, never a rewind): poc2 becomes a standby of poc1, is promoted, then poc1 is rebuilt as its standby"
# RULE (learned the hard way, first run): never destroy a volume until the copy you are keeping is
# verified — streaming, promoted, and taking writes. Each step below checks before the next destroys.
DUMP=".tmp/bank-$(date -u +%Y%m%dT%H%M%SZ).sql"; mkdir -p .tmp
echo "  safety net first: pg_dump of the current primary (poc1) -> $DUMP"; k1 -n bank exec postgres-standby-0 -c postgres -- pg_dump -U bank bank > "$DUMP"; echo "    $(grep -c 'INSERT\|COPY' "$DUMP") data statements, $(wc -c < "$DUMP" | tr -d ' ') bytes"
echo "  >>> step 1: rebuild poc2 from poc1 as a STANDBY (BOOTSTRAP_FROM=postgres-standby, empty volume, scale up)"
k2 -n bank set env sts/postgres -c bootstrap BOOTSTRAP_FROM=postgres-standby.bank.svc.cluster.local >/dev/null
k2 -n bank delete pvc data-postgres-0 --ignore-not-found --wait=true >/dev/null 2>&1; k2 -n bank scale sts/postgres --replicas=1 >/dev/null
T=$(wait_ready k2 postgres-0 ""); REC=$(psql2 'SELECT pg_is_in_recovery()'); STREAM=$(psql1 "SELECT count(*) FROM pg_stat_replication")
echo "  poc2 postgres-0 after ~${T}s: in_recovery=$REC; poc1 sees $STREAM standby streaming; chk-1001 on poc2 = $(psql2 "SELECT balance_cents FROM accounts WHERE id='chk-1001'")"
if [ "$REC" != t ] || [ "$STREAM" != 1 ]; then echo "  STOP: poc2 is not a verified streaming standby of poc1 — nothing else is touched. Dump kept at $DUMP."; exit 1; fi
echo "  >>> step 2: promote poc2, repoint accounts to postgres-primary, VERIFY a write lands there"
psql2 "SELECT pg_promote(true, 30)" >/dev/null; sleep 3; k2 -n bank set env sts/postgres -c bootstrap BOOTSTRAP_FROM= >/dev/null
k2 -n bank set env deploy/accounts PG_DSN="$PRIMARY_DSN" >/dev/null; k2 -n bank rollout status deploy/accounts --timeout=180s 2>&1 | tail -1 | sed 's/^/    /'
W=$(pay chk-1001 1 after-failback-step2); echo "  poc2 in_recovery=$(psql2 'SELECT pg_is_in_recovery()') timeline=$(psql2 'SELECT timeline_id FROM pg_control_checkpoint()'); a payment through accounts -> http $W"
if [ "$W" != 201 ]; then echo "  STOP: writes do not land on the promoted poc2 — poc1's volume is NOT deleted. Dump kept at $DUMP."; exit 1; fi
echo "  >>> step 3: only now rebuild poc1 as poc2's standby (its old timeline is obsolete; a rebuild, never a rewind)"
k1 -n bank scale sts/postgres-standby --replicas=0 >/dev/null; sleep 5; k1 -n bank delete pvc data-postgres-standby-0 --ignore-not-found --wait=true >/dev/null 2>&1
psql2 "SELECT pg_drop_replication_slot('standby_poc1')" >/dev/null 2>&1; psql2 "SELECT pg_create_physical_replication_slot('standby_poc1')" >/dev/null
k1 -n bank scale sts/postgres-standby --replicas=1 >/dev/null; T=$(wait_ready k1 postgres-standby-0 ""); echo "  poc1 standby rebuilt after ~${T}s: in_recovery=$(psql1 'SELECT pg_is_in_recovery()')"
echo "  final: primary(poc2) sees $(psql2 "SELECT count(*)||' standby, state='||coalesce(max(state),'none') FROM pg_stat_replication"); balances primary=$(psql2 "SELECT balance_cents FROM accounts WHERE id='chk-1001'") standby=$(psql1 "SELECT balance_cents FROM accounts WHERE id='chk-1001'"); a payment -> http $(pay chk-1001 1 after-failback); read -> $(baldb chk-1001)"
}
