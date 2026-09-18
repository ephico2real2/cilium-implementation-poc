#!/usr/bin/env bash
# check.sh — demo 53 PASS/FAIL rows (demo 40's row() style). Exit = FAIL count.
#   demos/53-grpc-parity/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
fails=0
row() { # ok|fail|warn  what  measured  rule
  local st
  case "$1" in
    ok)   st=PASS ;;
    fail) st=FAIL; fails=$((fails + 1)) ;;
    warn) st=WARN ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-70s %-52s %s\n' "$st" "$2" "$3" "$4"
}

POC1_GW=172.18.255.240
POC2_GW=172.18.255.177
POC1_HOST=grpc.poc.local
POC2_HOST=grpc.poc2.shop.poc.local
GRPCURL_IMG=fullstorydev/grpcurl:latest

printf '\n== demo 53 — gRPC parity on the Cilium clusters (poc1 re-run, poc2 first GRPCRoute)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# Live root: docs/root-ca.crt has been a different fingerprint from clustermesh-root-ca
# (demo 39 / lab-stack.sh). Prefer .tmp/root-ca.crt; export it if missing.
mkdir -p .tmp
if [ ! -s .tmp/root-ca.crt ]; then
  scripts/lab-trust.sh export kind-poc2 >/dev/null
fi
CA=.tmp/root-ca.crt
CA_NOTE=live
if [ -s docs/root-ca.crt ]; then
  docs_fp=$(openssl x509 -in docs/root-ca.crt -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}')
  live_fp=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}')
  if [ -n "$docs_fp" ] && [ "$docs_fp" = "$live_fp" ]; then
    CA=docs/root-ca.crt
    CA_NOTE=docs
  fi
fi
row ok "root CA for TLS rows" "$CA ($CA_NOTE)" "clustermesh-root-ca via scripts/lab-trust.sh export; docs/root-ca.crt only if fingerprints match"

oneline() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c1-80; }

# grpcurl in a container on the kind bridge (the image has no shell). TLS mounts the chosen CA.
grpcurl_plain() { # authority addr method-or-list
  docker run --rm --network kind "$GRPCURL_IMG" \
    -plaintext -max-time 10 -authority "$1" "$2" "$3" 2>&1
}
grpcurl_tls() { # authority addr method
  docker run --rm --network kind -v "$PWD/${CA}:/certs/root-ca.crt:ro" "$GRPCURL_IMG" \
    -cacert /certs/root-ca.crt -max-time 10 -authority "$1" "$2" "$3" 2>&1
}
is_serving() { printf '%s' "$1" | tr -d '[:space:]' | grep -q '"status":"SERVING"'; }

# (a) poc1 — demo 09 re-run exactly as written (plaintext, TLS, list)
out=$(grpcurl_plain "$POC1_HOST" "$POC1_GW:80" grpc.health.v1.Health/Check)
if is_serving "$out"; then
  row ok "poc1 h2c Health/Check @ $POC1_GW:80" \
    "$(oneline "$out")" \
    "grpcurl -plaintext -authority $POC1_HOST $POC1_GW:80 → {\"status\":\"SERVING\"}"
else
  row fail "poc1 h2c Health/Check @ $POC1_GW:80" \
    "$(oneline "$out")" \
    "grpcurl -plaintext -authority $POC1_HOST $POC1_GW:80 → {\"status\":\"SERVING\"}"
fi

out=$(grpcurl_tls "$POC1_HOST" "$POC1_GW:443" grpc.health.v1.Health/Check)
if is_serving "$out"; then
  row ok "poc1 TLS Health/Check @ $POC1_GW:443" \
    "$(oneline "$out")" \
    "grpcurl -cacert $CA -authority $POC1_HOST $POC1_GW:443 → {\"status\":\"SERVING\"}"
else
  row fail "poc1 TLS Health/Check @ $POC1_GW:443" \
    "$(oneline "$out")" \
    "grpcurl -cacert $CA -authority $POC1_HOST $POC1_GW:443 → {\"status\":\"SERVING\"}"
fi

list_ok() { # stdout of grpcurl list — Health plus both reflection services (demo 09); routedemo.Echo is a health status name, not a reflected service
  printf '%s' "$1" | grep -q 'grpc.health.v1.Health' &&
    printf '%s' "$1" | grep -q 'grpc.reflection.v1.ServerReflection' &&
    printf '%s' "$1" | grep -q 'grpc.reflection.v1alpha.ServerReflection'
}

out=$(grpcurl_plain "$POC1_HOST" "$POC1_GW:80" list)
if list_ok "$out"; then
  row ok "poc1 grpcurl list via reflection" \
    "$(oneline "$out")" \
    "list shows grpc.health.v1.Health and both ServerReflection services (demo 09)"
else
  row fail "poc1 grpcurl list via reflection" \
    "$(oneline "$out")" \
    "list shows grpc.health.v1.Health and both ServerReflection services (demo 09)"
fi

# (b) poc2 — the same three against shop-gw .177
out=$(grpcurl_plain "$POC2_HOST" "$POC2_GW:80" grpc.health.v1.Health/Check)
if is_serving "$out"; then
  row ok "poc2 h2c Health/Check @ $POC2_GW:80" \
    "$(oneline "$out")" \
    "grpcurl -plaintext -authority $POC2_HOST $POC2_GW:80 → {\"status\":\"SERVING\"}"
else
  row fail "poc2 h2c Health/Check @ $POC2_GW:80" \
    "$(oneline "$out")" \
    "grpcurl -plaintext -authority $POC2_HOST $POC2_GW:80 → {\"status\":\"SERVING\"}"
fi

out=$(grpcurl_tls "$POC2_HOST" "$POC2_GW:443" grpc.health.v1.Health/Check)
if is_serving "$out"; then
  row ok "poc2 TLS Health/Check @ $POC2_GW:443" \
    "$(oneline "$out")" \
    "grpcurl -cacert $CA -authority $POC2_HOST $POC2_GW:443 → {\"status\":\"SERVING\"}"
else
  row fail "poc2 TLS Health/Check @ $POC2_GW:443" \
    "$(oneline "$out")" \
    "grpcurl -cacert $CA -authority $POC2_HOST $POC2_GW:443 → {\"status\":\"SERVING\"}"
fi

out=$(grpcurl_plain "$POC2_HOST" "$POC2_GW:80" list)
if list_ok "$out"; then
  row ok "poc2 grpcurl list via reflection" \
    "$(oneline "$out")" \
    "list shows grpc.health.v1.Health and both ServerReflection services (demo 09)"
else
  row fail "poc2 grpcurl list via reflection" \
    "$(oneline "$out")" \
    "list shows grpc.health.v1.Health and both ServerReflection services (demo 09)"
fi

# (c) route Accepted on both parents, listener Programmed, grpc-tls Ready
route_parents() {
  kubectl --context kind-poc2 -n shop-edge get grpcroute grpc -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d.get("status",{}).get("parents") or []
acc=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("Accepted")=="True")
res=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("ResolvedRefs")=="True")
print(f"accepted={acc}/{len(ps)} resolved={res}/{len(ps)}")
' 2>/dev/null || echo "accepted=?/? resolved=?/?"
}
m=$(route_parents)
acc=${m#accepted=}; acc=${acc%% *}; a=${acc%%/*}; t=${acc##*/}
res=${m##*resolved=}; r=${res%%/*}; rt=${res##*/}
if [ "$a" = "$t" ] && [ "$r" = "$rt" ] && [ "${t:-0}" -ge 2 ]; then
  row ok "poc2 grpcroute/grpc Accepted on both parents" "$m" \
    "every parent Accepted=True and ResolvedRefs=True (≥ 2 parents: https-grpc and http)"
else
  row fail "poc2 grpcroute/grpc Accepted on both parents" "$m" \
    "every parent Accepted=True and ResolvedRefs=True (≥ 2 parents: https-grpc and http)"
fi

lprog=$(kubectl --context kind-poc2 -n shop-edge get gateway shop-gw -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for l in d.get("status",{}).get("listeners") or []:
    if l.get("name")=="https-grpc":
        cond={c["type"]:c["status"] for c in l.get("conditions") or []}
        print(cond.get("Programmed","?"))
        break
else:
    print("absent")
' 2>/dev/null || echo absent)
if [ "$lprog" = True ]; then
  row ok "poc2 shop-gw listener https-grpc Programmed" "Programmed=$lprog" \
    "status.listeners[name=https-grpc] Programmed=True"
else
  row fail "poc2 shop-gw listener https-grpc Programmed" "Programmed=${lprog:-?}" \
    "status.listeners[name=https-grpc] Programmed=True"
fi

ready=$(kubectl --context kind-poc2 -n shop-edge get certificate grpc-tls \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$ready" = True ]; then
  row ok "poc2 grpc-tls Ready" "Ready=$ready" "Certificate grpc-tls Ready=True"
else
  row fail "poc2 grpc-tls Ready" "Ready=${ready:-?}" "Certificate grpc-tls Ready=True"
fi

# (d) from the Mac: grpcurl is not installed locally (demo 09 says so) — WARN how to install
# unless command -v finds it, then run -authority + the IP (the --resolve equivalent).
if command -v grpcurl >/dev/null 2>&1; then
  out=$(grpcurl -plaintext -max-time 10 -authority "$POC2_HOST" "$POC2_GW:80" grpc.health.v1.Health/Check 2>&1)
  if is_serving "$out"; then
    row ok "Mac grpcurl h2c Health/Check @ $POC2_GW:80" \
      "$(oneline "$out")" \
      "local grpcurl -plaintext -authority $POC2_HOST $POC2_GW:80 → {\"status\":\"SERVING\"}"
  else
    row fail "Mac grpcurl h2c Health/Check @ $POC2_GW:80" \
      "$(oneline "$out")" \
      "local grpcurl -plaintext -authority $POC2_HOST $POC2_GW:80 → {\"status\":\"SERVING\"}"
  fi
else
  row warn "Mac grpcurl (not installed)" \
    "command -v grpcurl: not found" \
    "skip: brew install grpcurl, then grpcurl -plaintext -authority $POC2_HOST $POC2_GW:80 grpc.health.v1.Health/Check"
fi

exit "$fails"
