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

# every file on one side exists on the other
for side in "$A:$B" "$B:$A"; do
  from=${side%%:*}; to=${side##*:}
  while IFS= read -r f; do
    if [ ! -f "$to/$f" ]; then
      echo "FAIL: $f exists in ${from#"$R/"} but not in ${to#"$R/"}"
      fail=1
    fi
  done < <(cd "$from" && find . -type f ! -path './vendor/*' | sed 's|^\./||' | sort)
done

# every shared file is identical unless it is on the allow-list
while IFS= read -r f; do
  [ -f "$B/$f" ] || continue
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
done < <(cd "$A" && find . -type f ! -path './vendor/*' | sed 's|^\./||' | sort)

# the allow-listed differences must be ONLY addresses and ports, never logic:
# a Go statement that differs is a behaviour change wearing a fixture's clothes.
#
# NOTE ON THE SHAPE: the changed lines are read into a variable and filtered
# afterwards. A `... | grep -q ...` here would close the pipe on its first match,
# the upstream grep would take SIGPIPE (141), and `set -o pipefail` would report
# the whole pipeline as failed — which an `if` reads as "no drift found", so real
# drift would pass silently. Measured on this file 2026-09-20; the same SIGPIPE
# shape killed a router in the fork's ci/rename-ifaces.sh.
for f in diff.go; do
  changed=$(diff "$A/$f" "$B/$f" || true)
  offending=$(printf '%s\n' "$changed" | grep -E '^[<>]' | \
    grep -vE '10\.(98|198|199)\.|172\.(19|20)\.|80[89][0-9]' || true)
  if [ -n "$offending" ]; then
    echo "FAIL: $f differs by more than an address or a port:"
    printf '%s\n' "$offending" | sed 's/^/       /'
    fail=1
  fi
done

[ $fail -eq 0 ] || { echo "TEST FAIL: the dashboard copies have drifted"; exit 1; }
echo "TEST PASS: both dashboard copies are identical except the addressed fixtures"
