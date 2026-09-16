#!/usr/bin/env bash
# lab-policies.sh — the cf2cnp chapters on the lab, the way the demos do them: the raw flows are captured from Hubble
# and KEPT, cf2cnp generates the CiliumNetworkPolicy through its API (the observer's cf2cnp behind the Gateway), the
# generated file is VALIDATED three ways before anything applies it, the policy is applied and the audit flag dropped,
# and the application is tested again with the demo's own check so the line the chapter promises is measured — a 403
# from the proxy, a SYN nobody answers, a policy named on a FORWARDED flow (enhancement 004, phase 2; the operator,
# 2026-09-15: "capturing of raw flow and using cf2cnp to generate the ClusterNetworkPolicy and apply them and testing
# the app again … the generated policies are valid without syntax error").
#
#   scripts/lab-policies.sh all                 # every chapter below, in order (after scripts/lab-apps.sh all and a few
#                                               # minutes of scripts/lab-apps.sh rounds: the flows must exist first)
#   scripts/lab-policies.sh 26 27 30 …          # one or more
#
#   chapter  namespace        flows captured how                                         generated       enforced how; the line measured
#   26       cf2cnp-lab       get-flow.sh cli: ONE audit flow, pos → shop                one ingress     audit off on shop: pos FORWARDED by the
#                                                                                       policy          policy, the stranger DROPPED
#   27       cf2cnp-lab27     hubble observe: the AUDIT flows into the namespace, the    two policies    apply: pos 200, the stranger and the
#                             stranger and the kiosk left out (a release of the intent)  (front, back)   kiosk rc=1 (a caller with no rule)
#   32       cf2cnp-lab27     the kiosk's own flows (DROPPED — cf2cnp reads flows, not   the frontend    the merged policy applied: kiosk 200,
#                             verdicts); cf2cnp merge into the frontend's policy         policy, merged  the stranger still rc=1; merge idempotent
#   30       cf2cnp-lab30     hubble observe --protocol http: REQUEST records, the       L7 rules        the visibility policy replaced by
#                             stranger left out                                          (method+path)   default-deny + L7: /admin 403 (the proxy)
#   31       cf2cnp-lab       egress-flows.sh: pos's egress flows, with the names the    toFQDNs +       a name never observed is DROPPED;
#                             DNS proxy attached                                         the DNS rule    example.com still 200
#   35       shop-edge/core/… audit-flows.sh: the AUDIT flows into five namespaces       six policies    audit off everywhere: six 200s, three
#                                                                                       (one request)   rc=1 — the stranger twice, the shopper
#                                                                                                       straight at the catalog (never observed)
#
# The three validations, in order, each fatal: `cf2cnp validate` (the pinned binary, CF2CNP_VERSION, offline, against the embedded CRD and
# Cilium's own Sanitize — enhancement 003), `kubectl apply --dry-run=server` (the API server's schema), and after the apply
# the policy's own status condition Valid=True from the agent (gotcha #80: an accepted object can still protect nothing).
# Every flow file and every generated policy lands under $LAB_POLICIES_DIR (captures/policies) — the artifact holds the
# raw material, not only the conclusion.
set -euo pipefail; cd "$(dirname "$0")/.."
CTX="${LAB_STACK_CTX:-kind-poc1}"; D="${LAB_POLICIES_DIR:-captures/policies}"; export ROOT_CA="${ROOT_CA:-.tmp/root-ca.crt}"
CF2CNP_VERSION="${CF2CNP_VERSION:-0.8.0}"   # the binary; the observer's server is the chart's (demo 25) — both read the same Cilium spec
G=demos/26-cf2cnp-policy-from-flows/generate.sh; F=demos/26-cf2cnp-policy-from-flows/get-flow.sh
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1" >&2; exit 1; }   # stderr: a die inside $(…) must not vanish into the variable
k() { kubectl --context "$CTX" "$@"; }
hit() { # <ns> <pod> <container|-> <url> — one request, the status line the caller saw (rc=1: no answer at all)
  local c=(); [ "$3" != "-" ] && c=(-c "$3")
  k -n "$1" exec "$2" "${c[@]}" -- sh -c "wget -S -qO- --timeout=3 '$4' 2>&1 | grep -m1 'HTTP/'; echo rc=\$?" 2>/dev/null | tr '\n' ' '
}
show() { printf '  %-12s %-52s %s\n' "$2" "${4#http://}" "$(hit "$@")"; }
expect() { # <label> <text> <regex> — the chapter's promised line, measured: the text must match, or the chapter fails
  if printf '%s\n' "$2" | grep -qE "$3"; then printf '  ✓ %s\n' "$1"; else printf '%s\n' "$2" | sed 's/^/    /'; die "$1 — expected /$3/ in the output above"; fi
}
count_flows() { python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip() and "flow" in json.loads(l)))' "$1" 2>/dev/null || echo 0; }

cf2cnp_bin() { # the release binary, verified against the release's checksums (demo 32 Exercise 0), once per version
  local dir=".tmp/cf2cnp-$CF2CNP_VERSION" os arch tgz
  if [ ! -x "$dir/cf2cnp" ]; then
    os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
    tgz="cf2cnp_${CF2CNP_VERSION}_${os}_${arch}.tar.gz"; mkdir -p "$dir"
    ( cd "$dir" && curl -sSfL -O "https://github.com/ephico2real2/cf2cnp/releases/download/v$CF2CNP_VERSION/$tgz" \
        && curl -sSfL -O "https://github.com/ephico2real2/cf2cnp/releases/download/v$CF2CNP_VERSION/cf2cnp_${CF2CNP_VERSION}_checksums.txt" \
        && { sha256sum -c --ignore-missing "cf2cnp_${CF2CNP_VERSION}_checksums.txt" 2>/dev/null || shasum -a 256 -c --ignore-missing "cf2cnp_${CF2CNP_VERSION}_checksums.txt"; } >/dev/null \
        && tar -xzf "$tgz" cf2cnp ) || die "cf2cnp $CF2CNP_VERSION: download or checksum failed"
  fi
  echo "$dir/cf2cnp"
}
validate() { # <file…> — the three validations that must pass before a generated policy touches the cluster
  local b out; b=$(cf2cnp_bin)
  out=$("$b" validate "$@" 2>&1) || { printf '%s\n' "$out" | sed 's/^/    /'; die "cf2cnp validate refused $* (exit = documents refused)"; }
  printf '  ✓ cf2cnp validate: %s document(s) ok, none refused\n' "$(printf '%s\n' "$out" | grep -c ' ok$')"
  local f; for f in "$@"; do
    out=$(k apply --dry-run=server -f "$f" 2>&1) || { printf '%s\n' "$out" | sed 's/^/    /'; die "the API server refused $f"; }
    printf '  ✓ apply --dry-run=server: %s\n' "$(printf '%s\n' "$out" | tr '\n' ';' | cut -c1-140)"
  done
}
apply_valid() { # <file…> — apply, then every policy in the file must reach Valid=True (the agent's own verdict on the rule)
  local f names n ns name st _i
  for f in "$@"; do
    # the names from the apply's own output: ONE object for a one-document file, a `kind: List` for two or more (kubectl
    # 1.36, run 34922062949 — chapter 27's two policies got no Valid check) — both shapes taken (gotcha #106)
    names=$(k apply -f "$f" -o json | jq -r 'if .kind == "List" then .items[] else . end | select(.kind == "CiliumNetworkPolicy") | "\(.metadata.namespace)/\(.metadata.name)"')
    [ -n "$names" ] || die "no CiliumNetworkPolicy in $f's apply output"

    for n in $names; do ns=${n%%/*}; name=${n##*/}
      for _i in $(seq 1 30); do st=$(k -n "$ns" get cnp "$name" -o jsonpath='{.status.conditions[?(@.type=="Valid")].status}' 2>/dev/null || true); [ "$st" = True ] && break; sleep 1; done
      [ "$st" = True ] || { k -n "$ns" get cnp "$name" -o jsonpath='{.status.conditions}'; echo; die "$n is not Valid after 30 s (gotcha #80)"; }
      printf '  ✓ applied %s: Valid=True (%s)\n' "$n" "$(k -n "$ns" get cnp "$name" -o jsonpath='{.spec.description}' | cut -c1-110)"
    done
  done
}

c26() {
  say "chapter 26 — cf2cnp-lab: one audit flow (pos → shop) → one ingress policy → audit off on shop"
  mkdir -p "$D/26"; local out
  show cf2cnp-lab pos - http://shop.cf2cnp-lab/ >/dev/null   # a fresh request, so the relay's ring buffer holds the flow to fetch
  sleep 2; "$F" cli --verdict AUDIT --from-pod cf2cnp-lab/pos --to-pod cf2cnp-lab/shop > "$D/26/flow-pos-to-shop.json" || die "no AUDIT flow pos → shop in the relay (is shop under audit with the default-deny? scripts/lab-apps.sh lab26)"
  echo "  captured: $D/26/flow-pos-to-shop.json ($(python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["flow"]; print(f["traffic_direction"], f["verdict"], f["source"]["pod_name"], "→", f["destination"]["pod_name"], (f["l4"].get("TCP") or {}).get("destination_port"))' "$D/26/flow-pos-to-shop.json"))"
  "$G" "$D/26/flow-pos-to-shop.json" "$D/26/cnp-pos-to-shop.yaml" | sed 's/^/  /'
  validate "$D/26/cnp-pos-to-shop.yaml"; apply_valid "$D/26/cnp-pos-to-shop.yaml"
  demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Disabled | tail -1 | sed 's/^/  /'
  sleep 5; show cf2cnp-lab pos - http://shop.cf2cnp-lab/; show cf2cnp-lab stranger - http://shop.cf2cnp-lab/
  sleep 15; out=$(demos/26-cf2cnp-policy-from-flows/verify.sh 40s); printf '%s\n' "$out" | sed 's/^/  /'
  expect "pos → shop FORWARDED by the generated policy" "$out" 'pos +→ +shop[^ ]* +:80 +FORWARDED .*by shop'
  expect "stranger → shop DROPPED (policy denied)" "$out" 'stranger +→ +shop[^ ]* +:80 +DROPPED'
}
c27() {
  say "chapter 27 — cf2cnp-lab27: the AUDIT flows into the namespace, the stranger and the kiosk left out → two policies (a release)"
  mkdir -p "$D/27"
  hubble observe -P --kube-context "$CTX" --verdict AUDIT --to-namespace cf2cnp-lab27 --last 300 -o json 2>/dev/null > "$D/27/flows-audit-all.ndjson" || true
  # the intent, reviewed: the stranger is never a rule; the kiosk is demo 32's NEW caller, not part of this release
  python3 - "$D/27/flows-audit-all.ndjson" "$D/27/flows-audit.ndjson" <<'PY2'
import json,sys,collections
kept=0; left=collections.Counter(); who=collections.Counter()
with open(sys.argv[2],"w") as out:
    for l in open(sys.argv[1]):
        try: f=json.loads(l)["flow"]
        except Exception: continue
        src=f["source"].get("pod_name","?")
        if src.startswith(("stranger","kiosk")): left[src]+=1; continue
        out.write(l); kept+=1; who[(src.rsplit("-",2)[0], f["destination"].get("pod_name","?").rsplit("-",2)[0])]+=1
print("  AUDIT flows kept:", kept, "->", sys.argv[2], "| left out:", dict(left))
for (s,d),n in sorted(who.items()): print("   %4d  %s → %s" % (n,s,d))
PY2
  [ "$(count_flows "$D/27/flows-audit.ndjson")" -gt 0 ] || die "no AUDIT flows into cf2cnp-lab27 (scripts/lab-apps.sh lab27, then rounds)"
  "$G" "$D/27/flows-audit.ndjson" "$D/27/cnp-shop.yaml" | sed 's/^/  /'
  validate "$D/27/cnp-shop.yaml"; apply_valid "$D/27/cnp-shop.yaml"
  NS=cf2cnp-lab27 demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop-frontend Disabled | tail -1 | sed 's/^/  /'   # Exercise 4: enforce
  NS=cf2cnp-lab27 demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop-backend Disabled | tail -1 | sed 's/^/  /'
  sleep 5; show cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/; show cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/; show cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/
  expect "pos → shop-frontend 200 (a rule)" "$(hit cf2cnp-lab27 pos client http://shop-frontend.cf2cnp-lab27/)" 'HTTP/1.1 200'
  expect "the stranger: no answer (rc=1)" "$(hit cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/)" '^rc=1'
  expect "the kiosk, not in the release: no answer (rc=1)" "$(hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/)" '^rc=1'
}
c32() {
  say "chapter 32 — the operator loop: the kiosk's DROPPED flows merged into the frontend's policy with cf2cnp merge"
  mkdir -p "$D/32"; local b; b=$(cf2cnp_bin)
  [ -s "$D/27/cnp-shop.yaml" ] || die "chapter 27's policy file is missing — run chapter 27 first"
  # the INGRESS side only — the flows the frontend's node reports. Both sides (run 34922062949: 34 flows) make cf2cnp see
  # two workloads (an egress policy for the kiosk, an ingress one for the frontend) and `merge` refuses two targets; the
  # demo's recorded capture is 18 INGRESS DROPPED flows, the same shape
  hubble observe -P --kube-context "$CTX" --from-pod cf2cnp-lab27/kiosk --to-pod cf2cnp-lab27/shop-frontend --traffic-direction ingress --last 40 -o json 2>/dev/null > "$D/32/flows-kiosk.ndjson" || true
  echo "  captured: $D/32/flows-kiosk.ndjson ($(count_flows "$D/32/flows-kiosk.ndjson") flows, verdicts: $(python3 -c 'import json,sys,collections; print(dict(collections.Counter(json.loads(l)["flow"]["verdict"] for l in open(sys.argv[1]) if l.strip())))' "$D/32/flows-kiosk.ndjson"))"
  [ "$(count_flows "$D/32/flows-kiosk.ndjson")" -gt 0 ] || die "no ingress flows kiosk → shop-frontend in the relay"
  # merge takes ONE policy for ONE workload (demo 32 Exercise 3): the frontend's document out of chapter 27's two
  python3 - "$D/27/cnp-shop.yaml" "$D/32/shop-frontend.yaml" <<'PY'
import sys,re
docs=[d for d in re.split(r'^---\s*$', open(sys.argv[1]).read(), flags=re.M) if d.strip()]
front=[d for d in docs if re.search(r'^\s*name:\s*shop-frontend\s*$', d, flags=re.M)]
assert len(front)==1, "expected one shop-frontend document, found %d" % len(front)
open(sys.argv[2],"w").write(front[0].lstrip("\n")); print("  the frontend's policy split out ->", sys.argv[2])
PY
  "$b" merge --existing "$D/32/shop-frontend.yaml" --input "$D/32/flows-kiosk.ndjson" --output "$D/32/shop-frontend-merged.yaml" | sed 's/^/  merge: /'
  "$b" merge --existing "$D/32/shop-frontend-merged.yaml" --input "$D/32/flows-kiosk.ndjson" --output "$D/32/shop-frontend-merged-again.yaml" | sed 's/^/  merge again: /'
  cmp -s "$D/32/shop-frontend-merged.yaml" "$D/32/shop-frontend-merged-again.yaml" && echo "  ✓ merge is idempotent (the second merge changed nothing)" || die "the second merge changed the file"
  diff "$D/32/shop-frontend.yaml" "$D/32/shop-frontend-merged.yaml" | sed 's/^/    /' || true
  validate "$D/32/shop-frontend-merged.yaml"; apply_valid "$D/32/shop-frontend-merged.yaml"
  sleep 5; show cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/; show cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/
  expect "the kiosk, merged in: 200" "$(hit cf2cnp-lab27 kiosk client http://shop-frontend.cf2cnp-lab27/)" 'HTTP/1.1 200'
  expect "the stranger still: no answer (rc=1)" "$(hit cf2cnp-lab27 stranger client http://shop-frontend.cf2cnp-lab27/)" '^rc=1'
}
c30() {
  say "chapter 30 — cf2cnp-lab30: the proxy's REQUEST flows (the stranger left out) → L7 rules → the visibility policy replaced by default-deny + L7"
  mkdir -p "$D/30"; local out
  hubble observe -P --kube-context "$CTX" --namespace cf2cnp-lab30 --protocol http --last 300 -o json 2>/dev/null > "$D/30/flows-http-all.ndjson" || true
  python3 - "$D/30/flows-http-all.ndjson" "$D/30/flows-http-intent.ndjson" <<'PY'
import json,sys,collections
kept=0; paths=collections.Counter()
with open(sys.argv[2],"w") as out:
    for l in open(sys.argv[1]):
        try: f=json.loads(l)["flow"]
        except Exception: continue
        if f.get("l7",{}).get("type")!="REQUEST" or f["source"].get("pod_name","").startswith("stranger"): continue
        out.write(l); kept+=1; paths[(f["source"].get("pod_name","?").rsplit("-",2)[0], f["destination"].get("pod_name","?").rsplit("-",2)[0], f["l7"]["http"]["method"], f["l7"]["http"]["url"].split("/",3)[-1].split("?")[0])]+=1
print("  REQUEST records kept, stranger excluded:", kept, "->", sys.argv[2])
for (s,d,m,p),n in sorted(paths.items()): print("   %4d  %s → %s  %s /%s" % (n,s,d,m,p))
PY
  [ "$(count_flows "$D/30/flows-http-intent.ndjson")" -gt 0 ] || die "no HTTP REQUEST flows in cf2cnp-lab30 (is the visibility policy applied? scripts/lab-apps.sh lab30)"
  QUERY=l7=true "$G" "$D/30/flows-http-intent.ndjson" "$D/30/cnp-shop-l7.yaml" | sed 's/^/  /'
  echo "  the L7 rules generated:"; grep -nE 'method:|path:' "$D/30/cnp-shop-l7.yaml" | sed 's/^/    /'
  validate "$D/30/cnp-shop-l7.yaml"
  k delete -f demos/30-l7-rules/20-http-visibility.yaml >/dev/null; apply_valid demos/30-l7-rules/30-shop-default-deny-ingress.yaml "$D/30/cnp-shop-l7.yaml"
  sleep 5; out=$(demos/30-l7-rules/calls.sh); printf '%s\n' "$out" | sed 's/^/  /'
  expect "pos GET / → 200" "$out" '^pos +shop-frontend.cf2cnp-lab30/ +HTTP/1.1 200'
  expect "pos GET /checkout?promo=1 → 200 (the query string is in the regex)" "$out" 'checkout\?promo=1 +HTTP/1.1 200'
  expect "pos GET /admin → 403 from the proxy (never observed)" "$out" 'shop-frontend.cf2cnp-lab30/admin +HTTP/1.1 403'
  expect "shop-frontend → shop-backend /admin → 403" "$out" 'shop-backend.cf2cnp-lab30/admin +HTTP/1.1 403'
  expect "the stranger: no answer at L3/L4 (rc=1)" "$out" '^stranger +shop-frontend.cf2cnp-lab30/ +rc=1'
  demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 100 | grep -E 'admin|promo|source' | sed 's/^/  /' || true
}
c31() {
  say "chapter 31 — cf2cnp-lab/pos: its egress flows with the names the DNS proxy attached → a toFQDNs policy; a name never observed is dropped"
  mkdir -p "$D/31"
  show cf2cnp-lab pos - https://example.com/ >/dev/null; sleep 2
  demos/31-dns-visibility/egress-flows.sh cf2cnp-lab/pos "$D/31/flows-pos-egress.ndjson" 300 | sed 's/^/  /'
  [ "$(count_flows "$D/31/flows-pos-egress.ndjson")" -gt 0 ] || die "no egress flows from cf2cnp-lab/pos"
  grep -q '"destination_names"' "$D/31/flows-pos-egress.ndjson" || die "pos's flows carry no destination_names — the DNS-visibility rule is not on pos (scripts/lab-apps.sh dns)"
  QUERY=dnsVisibility=true "$G" "$D/31/flows-pos-egress.ndjson" "$D/31/cnp-pos-fqdn.yaml" | sed 's/^/  /'
  echo "  the names and the resolver rule generated:"; grep -nE 'matchName|matchPattern|k8s-app|toCIDR' "$D/31/cnp-pos-fqdn.yaml" | sed 's/^/    /'
  grep -q 'toFQDNs' "$D/31/cnp-pos-fqdn.yaml" || die "no toFQDNs rule in the generated policy"
  validate "$D/31/cnp-pos-fqdn.yaml"; apply_valid "$D/31/cnp-pos-fqdn.yaml"
  sleep 5; show cf2cnp-lab pos - https://example.com/; show cf2cnp-lab pos - https://github.com/
  expect "example.com (observed): 200" "$(hit cf2cnp-lab pos - https://example.com/)" 'HTTP/1.1 200'
  expect "github.com (never observed): no answer (rc=1)" "$(hit cf2cnp-lab pos - https://github.com/)" '^rc=1'
  hubble observe -P --kube-context "$CTX" --from-pod cf2cnp-lab/pos --verdict DROPPED --last 2 2>/dev/null | sed 's/^/  /' || true
}
c35() {
  say "chapter 35 — the shop platform: the AUDIT flows into five namespaces, one request → six policies → audit off everywhere"
  mkdir -p "$D/35"; local out
  demos/35-shop-platform/audit-flows.sh "$D/35/flows-audit.ndjson" 400 | sed 's/^/  /'
  [ "$(count_flows "$D/35/flows-audit.ndjson")" -gt 0 ] || die "no AUDIT flows into the shop namespaces (scripts/lab-apps.sh lab35, then rounds)"
  QUERY="exclude=app.kubernetes.io%2Fname%3Dstranger" "$G" "$D/35/flows-audit.ndjson" "$D/35/cnp-shop.yaml" | sed 's/^/  /'
  k create --dry-run=client -o json -f "$D/35/cnp-shop.yaml" | jq -r '"    \(.metadata.namespace)/\(.metadata.name): \(.spec.description)"'
  validate "$D/35/cnp-shop.yaml"; apply_valid "$D/35/cnp-shop.yaml"
  demos/35-shop-platform/audit-all.sh Disabled 2>&1 | tail -1 | sed 's/^/  /'
  sleep 5; out=$(demos/35-shop-platform/probe.sh); printf '%s\n' "$out" | sed 's/^/  /'
  [ "$(printf '%s\n' "$out" | grep -c 'HTTP/1.1 200')" -eq 6 ] && echo "  ✓ six 200s" || die "expected six 200s in probe.sh's output above"
  expect "the stranger at the catalog: rc=1" "$out" '^shop-clients +stranger +catalog.shop-core/items +rc=1'
  expect "the stranger at payments: rc=1" "$out" '^shop-clients +stranger +payment-gateway.shop-payments/charge +rc=1'
  expect "the shopper straight at the catalog (only ever observed through the gateway): rc=1" "$out" '^shop-clients +shopper +catalog.shop-core/items +rc=1'
  demos/35-shop-platform/verdicts.sh 200 | head -14 | sed 's/^/  /' || true
}

[ $# -ge 1 ] || { echo "usage: $0 all | 26 27 32 30 31 35"; exit 2; }
[ "$1" = all ] && set -- 26 27 32 30 31 35
mkdir -p "$D"; echo "cf2cnp $CF2CNP_VERSION: $(cf2cnp_bin) — $("$(cf2cnp_bin)" version 2>/dev/null | head -1)"
while [ $# -gt 0 ]; do case "$1" in 26|27|32|30|31|35) "c$1";; *) die "unknown chapter $1";; esac; shift; done
say "policies: $(find "$D" -name 'cnp-*.yaml' -o -name '*-merged.yaml' | wc -l | tr -d ' ') generated files under $D, every one validated three ways, applied and re-tested"
