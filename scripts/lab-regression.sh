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
#   14. The shop's public URL answers from a cluster (demos 40/41; WARN/SKIP if the VIP door is absent)
#   15. Cilium's own connectivity test, if a result file is present
#
# Exit code is the number of FAIL rows (0 = all good). WARN does not fail the run.
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1

# the pin the lab is built from: scripts/bootstrap/versions.env (a plain KEY=value; the bootstraps refuse a disagreement
# with lab-up.sh), or CILIUM_VERSION when the caller exports it — not lab-stack.sh's default, a third copy nothing checks
# (OB1's review, 2026-09-18)
EXPECT_CILIUM="${EXPECT_CILIUM:-${CILIUM_VERSION:-$(sed -n 's/^CILIUM_VERSION=//p' scripts/bootstrap/versions.env | head -1)}}"
# the lab may run its own build of that version (CILIUM_IMAGE in versions.env, demo 39): then row 1 expects that image
EXPECT_IMAGE="${CILIUM_IMAGE:-$(sed -n 's/^CILIUM_IMAGE=//p' scripts/bootstrap/versions.env | head -1)}"
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
# every name the check curls resolves to the Gateway's address read from the cluster — a runner has no /etc/hosts block
# and the Mac's can lag a demo; the same idea as the browser walk's resolve map
GW_ADDR=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
resolve() { # host — the curl flag that pins the name to the Gateway, or nothing when the cluster gave no address
  [ -n "$GW_ADDR" ] && printf -- '--resolve %s:443:%s' "$1" "$GW_ADDR"
}
grafana_get() { # path — GET Grafana with the lab CA and admin password
  # shellcheck disable=SC2046
  curl -sS -m 15 --cacert "$CA" $(resolve grafana.poc.local) -u "admin:${GRAFANA_PASS}" "https://grafana.poc.local$1"
}
prom_query() { # PromQL — instant query through Grafana's Prometheus proxy
  # shellcheck disable=SC2046
  curl -sS -m 20 --cacert "$CA" $(resolve grafana.poc.local) -u "admin:${GRAFANA_PASS}" \
    --data-urlencode "query=$1" \
    "https://grafana.poc.local/api/datasources/proxy/uid/${PROM_UID}/api/v1/query"
}

check_cilium_version() {
  local ctx c img ver ready dest parts rule ok=1
  parts=""
  for ctx in "$CTX" "$PEER_CTX"; do
    c=${ctx#kind-}
    img=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1) || { row fail "Both clusters run the expected Cilium version" "$(oneline "$img")" "image contains :v${EXPECT_CILIUM}@ and ready==desired on both"; return 0; }
    ready=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    dest=$(kubectl --context "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    if [ -n "$EXPECT_IMAGE" ]; then
      # the lab's own build: the DaemonSet's image is exactly the pinned repo:tag (no digest — a local build has none)
      ver=${img#*:}; ver=${ver%%@*}
      [ "$img" = "$EXPECT_IMAGE" ] || ok=0
      rule="image is ${EXPECT_IMAGE} (the lab's build of ${EXPECT_CILIUM}) and ready==desired on both"
    else
      ver=$(printf '%s' "$img" | sed -n 's/.*:\(v[0-9][0-9.]*\).*/\1/p')
      case "$img" in *":v${EXPECT_CILIUM}@"*) ;; *) ok=0 ;; esac
      rule="image contains :v${EXPECT_CILIUM}@ and ready==desired on both"
    fi
    ver=${ver:-?}
    parts="${parts:+$parts, }${c} ${ver} ${ready}/${dest}"
    [ "${dest:-0}" -gt 0 ] && [ "$ready" = "$dest" ] || ok=0
  done
  if [ "$ok" = 1 ]; then row ok "Both clusters run the expected Cilium version" "$parts" "$rule"
  else row fail "Both clusters run the expected Cilium version" "$parts" "$rule"; fi
}

check_agent_health() {
  local ctx c out val_c val_e parts bad=0
  parts=""
  for ctx in "$CTX" "$PEER_CTX"; do
    c=${ctx#kind-}
    out=$(cilium status --context "$ctx" --wait --wait-duration 60s 2>&1) || { row fail "Every Cilium agent is healthy" "$(oneline "$out")" "cilium status --wait exits 0 on both"; return 0; }
    out=$(printf '%s\n' "$out" | strip_ansi)
    val_c=$(printf '%s\n' "$out" | grep 'Cilium:' | head -1 | sed 's/.*Cilium:[[:space:]]*//' | awk '{print $1}')
    val_e=$(printf '%s\n' "$out" | grep 'Envoy DaemonSet:' | head -1 | sed 's/.*Envoy DaemonSet:[[:space:]]*//' | awk '{print $1}')
    parts="${parts:+$parts; }${c} Cilium=${val_c:-?} Envoy=${val_e:-?}"
    # exit 0 alone is not health — the two lines must read OK (the reviewers' finding, 2026-09-18)
    [ "${val_c:-}" = OK ] && [ "${val_e:-}" = OK ] || bad=1
  done
  if [ "${bad:-0}" = 0 ]; then row ok "Every Cilium agent is healthy" "$parts" "cilium status --wait exits 0 and reads Cilium: OK, Envoy DaemonSet: OK on both"
  else row fail "Every Cilium agent is healthy" "$parts" "cilium status --wait exits 0 and reads Cilium: OK, Envoy DaemonSet: OK on both"; fi
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
  # the names the stack always publishes, plus the demos' names only when their HTTPRoute exists — a trimmed CI lab has
  # no bank and no perf rig (probe-*), and a name that is not deployed is "skipped", not a regression (OB1, 2026-09-18)
  local url code host why bad=0 okc=0 total=0 fail_list="" skipped="" errf gw240 gw243 addr routes
  errf=$(mktemp)
  gw240=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  gw243=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  routes=$(k get httproute -A -o jsonpath='{range .items[*]}{.spec.hostnames[*]}{" "}{end}' 2>/dev/null || true)
  for url in \
    https://grafana.poc.local/api/health \
    https://cf2cnp.poc.local/health \
    https://shop-a.poc.local/ \
    https://shop.team-b.poc.local/ \
    https://probe-a.poc.local/ \
    https://probe.team-b.poc.local/ \
    https://bank.poc.local/
  do
    host=${url#https://}; host=${host%%/*}
    case " $routes " in *" $host "*) ;; *) skipped="${skipped:+$skipped, }$host"; continue ;; esac   # no HTTPRoute for it: not deployed here
    total=$((total+1))
    : >"$errf"
    case "$host" in *.team-b.poc.local) addr=${gw243:-$gw240} ;; *) addr=$gw240 ;; esac
    # curl prints 000 on DNS/timeout AND exits non-zero — do not append another 000
    code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' --cacert "$CA" ${addr:+--resolve "$host:443:$addr"} "$url" 2>"$errf" || true)
    code=${code:-000}
    why=$(tr '\n' ' ' <"$errf" | sed 's/[[:space:]]*$//')
    # bank may answer 200 or 401 (the login wall); every other name must be 200
    if [ "$code" = 200 ] || { [ "$host" = bank.poc.local ] && [ "$code" = 401 ]; }; then okc=$((okc+1))
    else bad=1; fail_list="${fail_list:+$fail_list, }${host} ${code}${why:+ ($why)}"; fi
  done
  rm -f "$errf"
  local measured="${okc}/${total} answered${skipped:+; not deployed here: $skipped}"
  if [ "$total" -lt 4 ]; then
    row fail "The Gateway answers on every published address" "only $total of the stack's names have a route: $routes" "grafana, cf2cnp, shop-a, shop.team-b always; bank, probe-* when deployed"
  elif [ "$bad" = 0 ]; then
    row ok "The Gateway answers on every published address" "$measured" "every deployed name answers 200 (bank may be 401)"
  else
    row fail "The Gateway answers on every published address" "$fail_list${skipped:+; not deployed here: $skipped}" "every deployed name answers 200 (bank may be 401)"
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
  # counted by jq, not by grep over the text: $(…) drops a trailing empty line, so a last lease without a holder would vanish
  empty=$(printf '%s' "$raw" | jq '[.items[] | select(.metadata.name | test("l2announce")) | select((.spec.holderIdentity // "") == "")] | length' 2>/dev/null || echo 1)
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
  if [ "$ready" = "$dest" ] && [ "${ready:-0}" -gt 0 ] && [ "${lines:-0}" -gt 0 ]; then
    row ok "The flow observer is streaming to Loki" "ready ${ready}/${dest}, ${lines} lines in 2 min" "ready == desired and log lines in the last 2 min > 0"
  else
    row fail "The flow observer is streaming to Loki" "ready ${ready}/${dest}, ${lines} lines in 2 min" "ready == desired and log lines in the last 2 min > 0"
  fi
}

check_cf2cnp() {
  local code img tag
  # shellcheck disable=SC2046
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' --cacert "$CA" $(resolve cf2cnp.poc.local) https://cf2cnp.poc.local/health 2>/dev/null || true)
  code=${code:-000}   # curl prints 000 itself on a failure — never append a second one
  img=$(k -n hubble-observer get deploy hubble-observer-cf2cnp -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1) || img="$img"
  tag=$(printf '%s' "$img" | sed -e 's/@.*//' -e 's/.*://')   # the tag is what follows the last colon, digest stripped
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
  errs=$(printf '%s\n' "$out" | grep -c '→ ERR' || true)   # check.sh prints "→ ERR" when the query itself failed — not data
  nodata=$((nodata + errs))
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

check_shop_url() {
  local code served hdr
  if ! kubectl --context "$CTX" -n shop-edge get gateway shop-vip-gw >/dev/null 2>&1; then
    row warn "The shop's public URL answers from a cluster" "shop-vip-gw absent" "SKIP when demos 40/41 are not applied"
    return 0
  fi
  hdr=$(curl -sk --resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/ \
          -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk 'tolower($0) ~ /^x-served-by:/ {print $2}' | tr -d '\r')
  case "$served" in
    poc1|poc2)
      if [ "$code" = 200 ]; then
        row ok "The shop's public URL answers from a cluster" "http_code=$code X-Served-By=$served" "200 and X-Served-By in {poc1,poc2}"
        return 0
      fi
      ;;
  esac
  row fail "The shop's public URL answers from a cluster" "http_code=${code:-000} X-Served-By=${served:-absent}" "200 and X-Served-By in {poc1,poc2}"
}

check_connectivity() {
  local f line n names only
  f="${CONNECTIVITY_RESULT:-.tmp/upgrade/connectivity-local.txt}"
  if [ ! -f "$f" ]; then
    row warn "Cilium's own connectivity test, if a result file is present" "not run" "0 failed, or only check-log-errors (the log scan)"
    return 0
  fi
  line=$(grep -E '❌ .*/[0-9]+ tests failed|✅ .*All [0-9]+ tests .* successful' "$f" | tail -1 | sed 's/[[:space:]]*$//')
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
  check_shop_url
  check_connectivity

  printf '\nsummary: %s PASS, %s FAIL, %s WARN — saved to %s\n' "$n_pass" "$n_fail" "$n_warn" "$OUT"
  exit "$n_fail"
} | tee "$OUT"
exit "${PIPESTATUS[0]}"
