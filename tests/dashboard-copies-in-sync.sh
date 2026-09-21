#!/usr/bin/env bash
# test: the two dashboard copies do not drift apart.
#
# demos/46-bgp-fabric/dashboard (Docker Desktop) and
# demos/46-bgp-fabric-colima/dashboard (Colima) are the same program. The copy
# exists because the old lab stays as it is while the Colima lab moves; nobody
# decided the two should behave differently. Every SOURCE file must therefore be
# byte-identical, and only the files listed in ALLOWED_DIFF below — fixtures that
# carry this family's addresses, and the README that names its port — may differ.
#
# Without this gate a fix lands in one copy and the other silently keeps the bug.
# usage: bash tests/dashboard-copies-in-sync.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
A="$R/demos/46-bgp-fabric/dashboard"
B="$R/demos/46-bgp-fabric-colima/dashboard"

# Fixtures and prose that legitimately differ: the Colima family is addressed
# 172.20.0.0/16 + 10.198.0.0/24, the Desktop family 172.19.0.0/16 + 10.98.0.0/24,
# and the dashboards publish different ports (8088 vs 8098).
ALLOWED_DIFF="README.md diff.go diff_test.go frr_json_test.go graph_test.go poller_holddown_test.go poller_test.go testdata/bgp-ipv4-established.json testdata/bgp-summary-established.json"

fail=0
for d in "$A" "$B"; do
  [ -d "$d" ] || { echo "FAIL: missing $d"; exit 1; }
done

# This gate compares what is IN THE REPOSITORY, so a path git ignores is
# skipped: `go build ./...` drops an 11 MB binary beside the source, and the
# gate would otherwise fail for anyone who builds. Nothing else is excluded —
# a vendor/ tree in one copy only (`go mod vendor` run in one directory) is a
# build-input fork, not an addressing difference, and neither copy is ignored.
# Ignoring a path is a deliberate act recorded in .gitignore, not silent drift.
tracked() {
  git -C "$R" check-ignore -q "$1" 2>/dev/null && return 1
  return 0
}

files_in() {
  (cd "$1" && find . -type f | sed 's|^\./||' | sort)
}

for side in "$A:$B" "$B:$A"; do
  from=${side%%:*}; to=${side##*:}
  while IFS= read -r f; do
    tracked "$from/$f" || continue
    if [ ! -f "$to/$f" ]; then
      echo "FAIL: $f exists in ${from#"$R/"} but not in ${to#"$R/"}"
      fail=1
    fi
  done < <(files_in "$from")
done

# every shared file is identical unless it is on the allow-list
while IFS= read -r f; do
  [ -f "$B/$f" ] || continue
  tracked "$A/$f" || continue
  case " $ALLOWED_DIFF " in *" $f "*) allowed=yes ;; *) allowed=no ;; esac
  if cmp -s "$A/$f" "$B/$f"; then
    if [ "$allowed" = yes ]; then
      echo "NOTE: $f is on the allow-list but is identical — drop it from ALLOWED_DIFF"
    fi
  elif [ "$allowed" = no ]; then
    echo "FAIL: $f differs between the two dashboard copies — port the change to both"
    diff "$A/$f" "$B/$f" | head -6 | sed 's/^/       /'
    fail=1
  fi
done < <(files_in "$A")

# The allow-listed differences must be ONLY addresses, ports and the image tag,
# never logic. This is done by REWRITING the Colima family's addressing into the
# Desktop family's and requiring what is left to be byte-identical — not by
# whitelisting changed lines that happen to contain an address.
#
# A per-line regex whitelist cannot do this job. When a changed line carries the
# family address on BOTH sides — `k == "10.98.0.11/32"` against
# `k == "10.198.0.11/32" && !r.Bestpath` — every `<` and `>` line matches the
# address pattern, so nothing is left to complain about and a behaviour fork in
# ECMP de-duplication passes clean (measured 2026-09-20, both holes reproduced).
# That version also only ever covered diff.go, so an assertion deleted from the
# Colima copy's poller_test.go passed too. Normalise-then-compare covers every
# allow-listed file and cannot be fooled by where the address sits on the line.
#
# The rewrite is one-way, Colima → Desktop, and each rule is an addressing fact:
#   10.198. → 10.98.   VIP range       172.20. → 172.19.   node LAN
#   10.199. → 10.99.   second VIP      8098    → 8088      published port
#   bgp-dashboard:colima → :local      the image each lab builds
# A legitimate new difference means a new rule here, stated as a fact, not a
# file dropped from the check.
canon() {
  sed -e 's/10\.198\./10.98./g' \
      -e 's/10\.199\./10.99./g' \
      -e 's/172\.20\./172.19./g' \
      -e 's/8098/8088/g' \
      -e 's/bgp-dashboard:colima/bgp-dashboard:local/g' "$1"
}

for f in $ALLOWED_DIFF; do
  [ -f "$A/$f" ] && [ -f "$B/$f" ] || continue
  offending=$(diff <(canon "$A/$f") <(canon "$B/$f") || true)
  if [ -n "$offending" ]; then
    echo "FAIL: $f differs by more than an address, a port or the image tag:"
    printf '%s\n' "$offending" | sed 's/^/       /'
    fail=1
  fi
done

[ $fail -eq 0 ] || { echo "TEST FAIL: the dashboard copies have drifted"; exit 1; }
echo "TEST PASS: both dashboard copies are identical except the addressed fixtures"
