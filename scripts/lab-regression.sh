#!/usr/bin/env bash
# lab-regression.sh — after an upgrade or a change, one table: each promise of the running lab, PASS or FAIL with the number.
#
#   scripts/lab-regression.sh
#
# A PASS means that promise is still true, measured just now on kind-poc1 and kind-poc2.
#   1. Both clusters run the expected Cilium version
#   2. Every Cilium agent is healthy
#   3. The two clusters see each other (Cluster Mesh)
#   4. The Gateway answers on every published address
#   5. Every Gateway listener is programmed
#   6. The load-balancer addresses have an owner (L2 leases)
#   7. Hubble metrics arrive from both clusters
#   8. Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)
#   9. The flow observer is streaming to Loki
#   10. cf2cnp (the policy generator) answers and is the expected version
#   11. Grafana has the lab's dashboards
#   12. The tutorial dashboards' queries return data
#   13. The two Gateway doors of demo 37 still behave
#   14. Cilium's own connectivity test, if a result file is present
#
# Exit code is the number of FAIL rows (0 = all good). WARN does not fail the run.
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1

# pin from lab-stack.sh so a version bump is picked up here without editing this file
EXPECT_CILIUM="${EXPECT_CILIUM:-$(grep -m1 'CILIUM_VERSION="${CILIUM_VERSION:-' scripts/lab-stack.sh | sed -E 's/.*:-([^}"]+).*/\1/')}"
# same idea: the default in lab-policies.sh, overridable by CF2CNP_VERSION
CF2CNP_VERSION="${CF2CNP_VERSION:-$(grep -m1 'CF2CNP_VERSION="${CF2CNP_VERSION:-' scripts/lab-policies.sh | sed -E 's/.*:-([^}"]+).*/\1/')}"
CTX="${CTX:-kind-poc1}"
PEER_CTX="${PEER_CTX:-kind-poc2}"
CA="${ROOT_CA:-.tmp/root-ca.crt}"
k() { kubectl --context "$CTX" "$@"; }

n_pass=0; n_fail=0; n_warn=0
row() { # ok|fail|warn  what  measured  rule
  local st
  case "$1" in
    ok)   st=PASS; n_pass=$((n_pass+1)) ;;
    fail) st=FAIL; n_fail=$((n_fail+1)) ;;
    warn) st=WARN; n_warn=$((n_warn+1)) ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-88s %-42s %s\n' "$st" "$2" "$3" "$4"
}

# one line, truncated, so a kubectl/curl dump does not blow the table
oneline() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c1-200; }
one_dec() { echo "$1" | awk '{printf "%.1f", $1}'; }
# strip the CLI's colour so grep sees "Cilium:"
strip_ansi() { sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }

# Grafana basic-auth + the Prometheus datasource uid (type prometheus)
grafana_pass() {
  k -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d | tr -d '\n'
}
grafana_get() { # path — GET Grafana with the lab CA and admin password
  curl -sS -m 15 --cacert "$CA" -u "admin:${GRAFANA_PASS}" "https://grafana.poc.local$1"
}
prom_query() { # PromQL — instant query through Grafana's Prometheus proxy
  curl -sS -m 20 --cacert "$CA" -u "admin:${GRAFANA_PASS}" \
    --data-urlencode "query=$1" \
    "https://grafana.poc.local/api/datasources/proxy/uid/${PROM_UID}/api/v1/query"
}

check_cilium_version() {
  local ctx c img ver ready dest parts ok=1
  parts=""
  for ctx in "$CTX" "$PEER_CTX"; do
    c=${ctx#kind-}
    img=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1) || { row fail "Both clusters run the expected Cilium version" "$(oneline "$img")" "image contains :v${EXPECT_CILIUM}@ and ready==desired on both"; return 0; }
    ready=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    dest=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    ver=$(printf '%s' "$img" | sed -n 's/.*:\(v[0-9][0-9.]*\).*/\1/p')
    ver=${ver:-?}
    parts="${parts:+$parts, }${c} ${ver} ${ready}/${dest}"
    case "$img" in *":v${EXPECT_CILIUM}@"*) ;; *) ok=0 ;; esac
    [ "${dest:-0}" -gt 0 ] && [ "$ready" = "$dest" ] || ok=0
  done
  if [ "$ok" = 1 ]; then row ok "Both clusters run the expected Cilium version" "$parts" "image contains :v${EXPECT_CILIUM}@ and ready==desired on both"
  else row fail "Both clusters run the expected Cilium version" "$parts" "image contains :v${EXPECT_CILIUM}@ and ready==desired on both"; fi
}

check_agent_health() {
  local ctx c out val_c val_e parts
  parts=""
  for ctx in "$CTX" "$PEER_CTX"; do
    c=${ctx#kind-}
    out=$(cilium status --context "$ctx" --wait --wait-duration 60s 2>&1) || { row fail "Every Cilium agent is healthy" "$(oneline "$out")" "cilium status --wait exits 0 on both"; return 0; }
    out=$(printf '%s\n' "$out" | strip_ansi)
    val_c=$(printf '%s\n' "$out" | grep 'Cilium:' | head -1 | sed 's/.*Cilium:[[:space:]]*//' | awk '{print $1}')
    val_e=$(printf '%s\n' "$out" | grep 'Envoy DaemonSet:' | head -1 | sed 's/.*Envoy DaemonSet:[[:space:]]*//' | awk '{print $1}')
    parts="${parts:+$parts; }${c} Cilium=${val_c:-?} Envoy=${val_e:-?}"
  done
  row ok "Every Cilium agent is healthy" "$parts" "cilium status --wait exits 0 on both"
}

check_clustermesh() {
  local ctx c out line parts ok=1
  parts=""
  for ctx in "$CTX" "$PEER_CTX"; do
    c=${ctx#kind-}
    out=$(cilium clustermesh status --context "$ctx" 2>&1) || { row fail "The two clusters see each other (Cluster Mesh)" "$(oneline "$out")" "clustermesh status exits 0 and contains All 2 nodes are connected"; return 0; }
    line=$(printf '%s\n' "$out" | grep -F 'All 2 nodes are connected' | head -1 | sed 's/^[[:space:]]*//')
    if [ -z "$line" ]; then ok=0; line="missing 'All 2 nodes are connected'"; fi
    parts="${parts:+$parts; }${c}: ${line}"
  done
  if [ "$ok" = 1 ]; then row ok "The two clusters see each other (Cluster Mesh)" "$parts" "clustermesh status exits 0 and contains All 2 nodes are connected"
  else row fail "The two clusters see each other (Cluster Mesh)" "$parts" "clustermesh status exits 0 and contains All 2 nodes are connected"; fi
}

check_gateway_urls() {
  local url code host why bad=0 okc=0 fail_list="" errf gw240 gw243 addr
  errf=$(mktemp)
  # resolve the names to the Gateways' addresses read from the cluster — the runner has no /etc/hosts block and the Mac's
  # may lag a demo (probe-a.poc.local was missing from it on 2026-09-18); the browser walk resolves the same way
  gw240=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  gw243=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  # bank may answer 200 or 401 (the login wall); every other name must be 200
  for url in \
    https://grafana.poc.local/api/health \
    https://cf2cnp.poc.local/health \
    https://shop-a.poc.local/ \
    https://shop.team-b.poc.local/ \
    https://probe-a.poc.local/ \
    https://probe.team-b.poc.local/ \
    https://bank.poc.local/
  do
    : >"$errf"
    # curl prints 000 on DNS/timeout AND exits non-zero — do not append another 000
    host=${url#https://}; host=${host%%/*}
    case "$host" in *.team-b.poc.local) addr=${gw243:-$gw240} ;; *) addr=$gw240 ;; esac
    code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' --cacert "$CA" ${addr:+--resolve "$host:443:$addr"} "$url" 2>"$errf" || true)
    code=${code:-000}
    why=$(tr '\n' ' ' <"$errf" | sed 's/[[:space:]]*$//')
    if [ "$url" = "https://bank.poc.local/" ]; then
      if [ "$code" = 200 ] || [ "$code" = 401 ]; then okc=$((okc+1))
      else bad=1; fail_list="${fail_list:+$fail_list, }${host} ${code}${why:+ ($why)}"; fi
    elif [ "$code" = 200 ]; then okc=$((okc+1))
    else bad=1; fail_list="${fail_list:+$fail_list, }${host} ${code}${why:+ ($why)}"; fi
  done
  rm -f "$errf"
  if [ "$bad" = 0 ]; then
    if [ -z "$fail_list" ] && [ "$okc" = 7 ]; then
      row ok "The Gateway answers on every published address" "7/7 200" "all 7 URLs return 200 (bank may be 401)"
    else
      row ok "The Gateway answers on every published address" "${okc}/7 200" "all 7 URLs return 200 (bank may be 401)"
    fi
  else
    row fail "The Gateway answers on every published address" "$fail_list" "all 7 URLs return 200 (bank may be 401)"
  fi
}

check_listeners() {
  local raw n t
  raw=$(k get gateway.gateway.networking.k8s.io -A -o json 2>&1) || { row fail "Every Gateway listener is programmed" "$(oneline "$raw")" "every listener Programmed=True on kind-poc1"; return 0; }
  n=$(printf '%s' "$raw" | jq '[.items[].status.listeners[]?] | length' 2>/dev/null || echo 0)
  t=$(printf '%s' "$raw" | jq '[.items[].status.listeners[]?.conditions[]? | select(.type=="Programmed" and .status=="True")] | length' 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ] && [ "$n" = "$t" ]; then row ok "Every Gateway listener is programmed" "${n} listeners, ${t} True" "every listener Programmed=True on kind-poc1"
  else row fail "Every Gateway listener is programmed" "${n} listeners, ${t} True" "every listener Programmed=True on kind-poc1"; fi
}

check_l2_leases() {
  local raw names holders n empty
  raw=$(k -n kube-system get leases -o json 2>&1) || { row fail "The load-balancer addresses have an owner (L2 leases)" "$(oneline "$raw")" "every l2announce lease has a holder"; return 0; }
  names=$(printf '%s' "$raw" | jq -r '.items[] | select(.metadata.name | test("l2announce")) | .metadata.name' 2>/dev/null)
  holders=$(printf '%s' "$raw" | jq -r '.items[] | select(.metadata.name | test("l2announce")) | .spec.holderIdentity // ""' 2>/dev/null)
  n=$(printf '%s\n' "$names" | grep -c . || true)
  empty=$(printf '%s\n' "$holders" | grep -c '^$' || true)
  holders=$(printf '%s\n' "$holders" | grep -v '^$' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ "${n:-0}" -gt 0 ] && [ "${empty:-0}" = 0 ]; then
    row ok "The load-balancer addresses have an owner (L2 leases)" "${n} leases, holders: ${holders}" "every l2announce lease has a holder"
  else
    row fail "The load-balancer addresses have an owner (L2 leases)" "${n} leases, holders: ${holders:-none}" "every l2announce lease has a holder"
  fi
}

check_hubble_both() {
  local raw p1 p2 m
  raw=$(prom_query 'sum by (cluster) (rate(hubble_flows_processed_total[5m]))' 2>&1) || { row fail "Hubble metrics arrive from both clusters" "$(oneline "$raw")" "rate > 0 for poc1 and poc2"; return 0; }
  printf '%s' "$raw" | jq -e '.status=="success"' >/dev/null 2>&1 || { row fail "Hubble metrics arrive from both clusters" "$(oneline "$raw")" "rate > 0 for poc1 and poc2"; return 0; }
  p1=$(printf '%s' "$raw" | jq -r '[.data.result[] | select(.metric.cluster=="poc1") | .value[1]][0] // empty')
  p2=$(printf '%s' "$raw" | jq -r '[.data.result[] | select(.metric.cluster=="poc2") | .value[1]][0] // empty')
  m="poc1 ${p1:-missing}/s, poc2 ${p2:-missing}/s"
  if [ -n "${p1:-}" ] && [ -n "${p2:-}" ]; then
    m="poc1 $(one_dec "$p1")/s, poc2 $(one_dec "$p2")/s"
    if awk -v a="$p1" -v b="$p2" 'BEGIN{exit !(a+0>0 && b+0>0)}'; then
      row ok "Hubble metrics arrive from both clusters" "$m" "rate > 0 for poc1 and poc2"
      return 0
    fi
  fi
  row fail "Hubble metrics arrive from both clusters" "$m" "rate > 0 for poc1 and poc2"
}

check_verdicts() {
  local raw fwd drop m
  raw=$(prom_query 'sum by (verdict) (rate(hubble_flows_processed_total{cluster="poc1"}[5m]))' 2>&1) || { row fail "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "$(oneline "$raw")" "FORWARDED > 0 and DROPPED > 0 on poc1"; return 0; }
  printf '%s' "$raw" | jq -e '.status=="success"' >/dev/null 2>&1 || { row fail "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "$(oneline "$raw")" "FORWARDED > 0 and DROPPED > 0 on poc1"; return 0; }
  fwd=$(printf '%s' "$raw" | jq -r '[.data.result[] | select(.metric.verdict=="FORWARDED" or .metric.verdict=="forwarded") | .value[1]][0] // empty')
  drop=$(printf '%s' "$raw" | jq -r '[.data.result[] | select(.metric.verdict=="DROPPED" or .metric.verdict=="dropped") | .value[1]][0] // empty')
  m="FORWARDED ${fwd:-missing}/s, DROPPED ${drop:-missing}/s"
  if [ -n "${fwd:-}" ] && [ -n "${drop:-}" ]; then
    m="FORWARDED $(one_dec "$fwd")/s, DROPPED $(one_dec "$drop")/s"
    if awk -v a="$fwd" -v b="$drop" 'BEGIN{exit !(a+0>0 && b+0>0)}'; then
      row ok "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "$m" "FORWARDED > 0 and DROPPED > 0 on poc1"
      return 0
    fi
  fi
  row fail "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "$m" "FORWARDED > 0 and DROPPED > 0 on poc1"
}

check_observer() {
  local ready dest lines
  ready=$(k -n hubble-observer get deploy hubble-observer -o jsonpath='{.status.readyReplicas}' 2>&1) || { row fail "The flow observer is streaming to Loki" "$(oneline "$ready")" "ready 1/1 and log lines in the last 2 min > 0"; return 0; }
  dest=$(k -n hubble-observer get deploy hubble-observer -o jsonpath='{.status.replicas}' 2>/dev/null || echo 1)
  dest=${dest:-1}
  ready=${ready:-0}
  lines=$(k -n hubble-observer logs deploy/hubble-observer --since=2m 2>/dev/null | wc -l | tr -d ' ')
  lines=${lines:-0}
  if [ "$ready" = 1 ] && [ "${lines:-0}" -gt 0 ]; then
    row ok "The flow observer is streaming to Loki" "ready ${ready}/${dest}, ${lines} lines in 2 min" "ready 1/1 and log lines in the last 2 min > 0"
  else
    row fail "The flow observer is streaming to Loki" "ready ${ready}/${dest}, ${lines} lines in 2 min" "ready 1/1 and log lines in the last 2 min > 0"
  fi
}

check_cf2cnp() {
  local code img tag
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' --cacert "$CA" https://cf2cnp.poc.local/health 2>/dev/null || echo 000)
  img=$(k -n hubble-observer get deploy hubble-observer-cf2cnp -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1) || img="$img"
  tag=$(printf '%s' "$img" | sed -n 's|.*/[^:]*:\([^@]*\).*|\1|p')
  tag=${tag:-?}
  if [ "$code" = 200 ] && [ "$tag" = "$CF2CNP_VERSION" ]; then
    row ok "cf2cnp (the policy generator) answers and is the expected version" "health ${code}, image ${tag}" "health 200 and image tag ${CF2CNP_VERSION}"
  else
    row fail "cf2cnp (the policy generator) answers and is the expected version" "health ${code}, image ${tag}" "health 200 and image tag ${CF2CNP_VERSION}"
  fi
}

check_dashboards() {
  local raw have miss uid got
  raw=$(grafana_get '/api/search?type=dash-db' 2>&1) || { row fail "Grafana has the lab's dashboards" "$(oneline "$raw")" "9/9 uids present"; return 0; }
  have=$(printf '%s' "$raw" | jq -r '.[].uid' 2>/dev/null) || { row fail "Grafana has the lab's dashboards" "$(oneline "$raw")" "9/9 uids present"; return 0; }
  miss=""
  for uid in hubble-observer-23862 hubble-l7-http-by-app hubble-metrics-per-cluster \
             tut-1-question tut-2-time tut-3-colour tut-4-meaning tut-5-grow tut-6-cilium; do
    printf '%s\n' "$have" | grep -qx "$uid" || miss="${miss:+$miss, }${uid}"
  done
  if [ -z "$miss" ]; then row ok "Grafana has the lab's dashboards" "9/9 present" "9/9 uids present"
  else
    got=$((9 - $(printf '%s\n' "$miss" | tr ',' '\n' | grep -c . || true)))
    row fail "Grafana has the lab's dashboards" "${got}/9 present, missing: ${miss}" "9/9 uids present"
  fi
}

check_tutorial_queries() {
  local out nodata panels
  if [ ! -f demos/38-grafana-visual-grammar/check.sh ]; then
    row fail "The tutorial dashboards' queries return data" "demos/38-grafana-visual-grammar/check.sh: not found" "0 NO DATA lines (count → lines as panels)"
    return 0
  fi
  out=$(bash demos/38-grafana-visual-grammar/check.sh 2>&1) || true
  nodata=$(printf '%s\n' "$out" | grep -c 'NO DATA' || true)
  panels=$(printf '%s\n' "$out" | grep -c '→' || true)
  if [ "${nodata:-0}" = 0 ] && [ "${panels:-0}" -gt 0 ]; then
    row ok "The tutorial dashboards' queries return data" "${panels} panels, 0 NO DATA" "0 NO DATA lines (count → lines as panels)"
  else
    row fail "The tutorial dashboards' queries return data" "${panels} panels, ${nodata} NO DATA" "0 NO DATA lines (count → lines as panels)"
  fi
}

check_demo37_doors() {
  local out sec1 n a240 a243
  if [ ! -f demos/37-two-gateways/check.sh ]; then
    row fail "The two Gateway doors of demo 37 still behave" "demos/37-two-gateways/check.sh: not found" "2 Programmed=True doors with addresses"
    return 0
  fi
  out=$(bash demos/37-two-gateways/check.sh 2>&1) || true
  sec1=$(printf '%s\n' "$out" | sed -n '/^== 1\./,/^== 2\./p')
  n=$(printf '%s\n' "$sec1" | grep -c 'Programmed=True' || true)
  a240=$(printf '%s\n' "$sec1" | grep 'routes/routes-gw' | head -1 | sed -n 's/.*address=\([^ ]*\).*/\1/p')
  a243=$(printf '%s\n' "$sec1" | grep 'team-b/team-b-gw' | head -1 | sed -n 's/.*address=\([^ ]*\).*/\1/p')
  if [ "${n:-0}" = 2 ] && [ -n "${a240:-}" ] && [ "$a240" != '?' ] && [ -n "${a243:-}" ] && [ "$a243" != '?' ]; then
    row ok "The two Gateway doors of demo 37 still behave" "2 doors Programmed, ${a240} / ${a243}" "2 Programmed=True doors with addresses"
  else
    row fail "The two Gateway doors of demo 37 still behave" "${n:-0} doors Programmed, ${a240:-?} / ${a243:-?}" "2 Programmed=True doors with addresses"
  fi
}

check_connectivity() {
  local f line n names only
  f="${CONNECTIVITY_RESULT:-.tmp/upgrade/connectivity-local.txt}"
  if [ ! -f "$f" ]; then
    row warn "Cilium's own connectivity test, if a result file is present" "not run" "0 failed, or only check-log-errors (the log scan)"
    return 0
  fi
  line=$(grep -E '❌ .*/[0-9]+ tests failed|✅ All [0-9]+ tests .* successful' "$f" | tail -1 | sed 's/[[:space:]]*$//')
  if [ -z "$line" ]; then
    row fail "Cilium's own connectivity test, if a result file is present" "no summary line in ${f}" "0 failed, or only check-log-errors (the log scan)"
    return 0
  fi
  case "$line" in
    ✅*) row ok "Cilium's own connectivity test, if a result file is present" "$line" "0 failed, or only check-log-errors (the log scan)"; return 0 ;;
  esac
  n=$(printf '%s' "$line" | sed -n 's/.*❌ \([0-9]*\)\/[0-9]* tests failed.*/\1/p')
  n=${n:-1}
  if [ "$n" = 0 ]; then
    row ok "Cilium's own connectivity test, if a result file is present" "$line" "0 failed, or only check-log-errors (the log scan)"
    return 0
  fi
  names=$(sed -n '/Test Report/,$p' "$f" | grep -oE 'Test \[[^]]+\]' | sed 's/Test \[//;s/\]//' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  only=$(sed -n '/Test Report/,$p' "$f" | grep -oE 'Test \[[^]]+\]' | sed 's/Test \[//;s/\]//' | sort -u)
  if [ "$n" = 1 ] && [ "$only" = "check-log-errors" ]; then
    row ok "Cilium's own connectivity test, if a result file is present" "${line} — only the log scan failed" "0 failed, or only check-log-errors (the log scan)"
  else
    row fail "Cilium's own connectivity test, if a result file is present" "${line} failed: ${names:-unparsed}" "0 failed, or only check-log-errors (the log scan)"
  fi
}

# --- run: tee the whole table to output/regression/<UTC timestamp>.txt ---
OUT="output/regression/$(date -u +%Y%m%dT%H%M%SZ).txt"
mkdir -p output/regression
{
  printf '\n== lab regression %s — contexts %s %s — expected Cilium %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CTX" "$PEER_CTX" "$EXPECT_CILIUM"
  printf '  %-6s %-88s %-42s %s\n' STATUS WHAT MEASURED RULE

  # Grafana password and Prometheus uid: rows 7, 8, 11 need both; a miss is a real FAIL on those rows
  GRAFANA_PASS=$(grafana_pass 2>/dev/null || true)
  PROM_UID=""
  if [ -n "${GRAFANA_PASS:-}" ]; then
    PROM_UID=$(grafana_get /api/datasources 2>/dev/null | jq -r '[.[]? | select(.type=="prometheus")][0].uid // empty' 2>/dev/null || true)
  fi

  check_cilium_version
  check_agent_health
  check_clustermesh
  check_gateway_urls
  check_listeners
  check_l2_leases
  if [ -z "${GRAFANA_PASS:-}" ]; then
    row fail "Hubble metrics arrive from both clusters" "grafana admin-password unreadable" "rate > 0 for poc1 and poc2"
    row fail "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "grafana admin-password unreadable" "FORWARDED > 0 and DROPPED > 0 on poc1"
  elif [ -z "${PROM_UID:-}" ]; then
    row fail "Hubble metrics arrive from both clusters" "no Prometheus datasource uid" "rate > 0 for poc1 and poc2"
    row fail "Network policy is still enforcing (drops exist) and traffic still flows (forwards exist)" "no Prometheus datasource uid" "FORWARDED > 0 and DROPPED > 0 on poc1"
  else
    check_hubble_both
    check_verdicts
  fi
  check_observer
  check_cf2cnp
  if [ -z "${GRAFANA_PASS:-}" ]; then
    row fail "Grafana has the lab's dashboards" "grafana admin-password unreadable" "9/9 uids present"
  else
    check_dashboards
  fi
  check_tutorial_queries
  check_demo37_doors
  check_connectivity

  printf '\nsummary: %s PASS, %s FAIL, %s WARN — saved to %s\n' "$n_pass" "$n_fail" "$n_warn" "$OUT"
  exit "$n_fail"
} | tee "$OUT"
exit "${PIPESTATUS[0]}"
