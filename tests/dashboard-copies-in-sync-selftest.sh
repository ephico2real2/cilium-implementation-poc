#!/usr/bin/env bash
# test: tests/dashboard-copies-in-sync.sh actually catches drift.
#
# The gate is the only thing standing between "a fix landed in one dashboard
# copy" and "the other copy silently keeps the bug", so the gate itself is
# tested: each case below plants ONE drift in a throwaway copy of the two
# dashboards and asserts the gate exits non-zero. Nothing in the repository is
# written — the cases run in `mktemp -d`.
#
# Cases 2 and 3 are the two holes measured 2026-09-20 in the per-line regex
# version of the gate: a logic change whose `<` and `>` lines both carry their
# family's address, and a drift in an allow-listed file that was never
# logic-checked. Both passed that gate; both fail this one.
# usage: bash tests/dashboard-copies-in-sync-selftest.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
GATE="$R/tests/dashboard-copies-in-sync.sh"
[ -f "$GATE" ] || { echo "FAIL: missing $GATE"; exit 1; }

fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A pristine two-copy tree, laid out as the gate expects (it resolves the repo
# root from its own dirname/..).
#
# The files come from `git ls-files`, not from `cp -R`: the throwaway tree is
# not a git repository, so the gate's "skip what git ignores" step cannot work
# inside it, and a copied build artefact would fail case 1 for anyone who had
# run `go build`. Copying what the REPOSITORY holds is also the honest thing to
# test, because that is exactly what the gate claims to compare.
fresh() {
  local d="$work/case$1"
  rm -rf "$d"; mkdir -p "$d/tests"
  cp "$GATE" "$d/tests/"
  while IFS= read -r f; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$R/$f" "$d/$f"
  done < <(git -C "$R" ls-files --cached --others --exclude-standard \
    'demos/46-bgp-fabric/dashboard/*' 'demos/46-bgp-fabric-colima/dashboard/*')
  printf '%s' "$d"
}

# expect <PASS|FAIL> <dir> <description>
expect() {
  local want=$1 dir=$2 desc=$3 out rc
  out=$(cd "$dir" && bash tests/dashboard-copies-in-sync.sh 2>&1) && rc=0 || rc=$?
  if [ "$want" = PASS ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $desc — the gate rejected a clean tree (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/       /'
    fail=1
  elif [ "$want" = FAIL ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: $desc — the gate PASSED drift it must catch"
    fail=1
  else
    echo "  ok: $desc"
  fi
}

# 1. the tree as it stands must pass, or every case below is meaningless
d=$(fresh 1)
expect PASS "$d" "the current tree passes"

# 2. logic drift in an allow-listed source file, on lines that BOTH carry their
#    family's address — the shape a per-line address whitelist cannot see
d=$(fresh 2)
perl -0pi -e 's/\t\tif nextByPrefix\[k\] \{/\t\tif nextByPrefix[k] || k == "10.98.0.11\/32" {/' \
  "$d/demos/46-bgp-fabric/dashboard/diff.go"
perl -0pi -e 's/\t\tif nextByPrefix\[k\] \{/\t\tif nextByPrefix[k] || (k == "10.198.0.11\/32" \&\& !r.Bestpath) {/' \
  "$d/demos/46-bgp-fabric-colima/dashboard/diff.go"
expect FAIL "$d" "diff.go logic drift hidden behind an address on both sides"

# 3. an assertion dropped from an allow-listed TEST file: the Colima copy would
#    keep passing a test the Desktop copy still enforces
d=$(fresh 3)
perl -0pi -e 's/if !snap\.Routers\[0\]\.Reachable \|\| snap\.Routers\[0\]\.LastSeen != nowRFC3339ms\(t0\) \{/if !snap.Routers[0].Reachable {/' \
  "$d/demos/46-bgp-fabric-colima/dashboard/poller_test.go"
expect FAIL "$d" "poller_test.go assertion deleted from one copy"

# 4. a vendor tree in one copy only — that copy builds against different sources
d=$(fresh 4)
mkdir -p "$d/demos/46-bgp-fabric-colima/dashboard/vendor/github.com/coder/websocket"
echo 'package websocket' > "$d/demos/46-bgp-fabric-colima/dashboard/vendor/github.com/coder/websocket/ws.go"
expect FAIL "$d" "vendor/ present in one copy only"

# 5. an ordinary file in one copy only
d=$(fresh 5)
echo 'package main' > "$d/demos/46-bgp-fabric/dashboard/extra.go"
expect FAIL "$d" "a source file added to one copy only"

# 6. a non-allow-listed file edited in one copy only
d=$(fresh 6)
printf '\n/* colima only */\n' >> "$d/demos/46-bgp-fabric-colima/dashboard/static/app.css"
expect FAIL "$d" "app.css edited in one copy only"

# 7. a fixture whose MEANING changed rather than its addresses: an allow-listed
#    testdata file whose peer state is flipped is a behaviour change.
d=$(fresh 7)
fixture="$d/demos/46-bgp-fabric-colima/dashboard/testdata/bgp-summary-established.json"
# the fixture is pretty-printed, so the space after the colon is part of it
sed -i '' 's/"state": "Established"/"state": "Idle"/' "$fixture"
if cmp -s "$R/demos/46-bgp-fabric-colima/dashboard/testdata/bgp-summary-established.json" "$fixture"; then
  echo "FAIL: case 7 planted nothing — the fixture no longer matches the pattern it edits"
  fail=1
else
  expect FAIL "$d" "a testdata peer state flipped in one copy"
fi

# 8. a build artefact must NOT fail the gate. `go build ./...` drops the
#    compiled binary beside the source in whichever copy you built; it is
#    gitignored, so it is not part of the repository and the gate skips it.
#    This case runs against the real repo, because git ignore rules only exist
#    there — the throwaway copies above are not git repositories.
artefact="$R/demos/46-bgp-fabric-colima/dashboard/bgp-dashboard"
if [ -e "$artefact" ]; then
  echo "  skip: a real build artefact is already present; not overwriting it"
else
  cleanup_artefact() { rm -f "$artefact"; }
  trap 'cleanup_artefact; rm -rf "$work"' EXIT
  printf 'not really a binary\n' > "$artefact"
  if ! git -C "$R" check-ignore -q "$artefact"; then
    echo "FAIL: demos/*/dashboard/bgp-dashboard is not gitignored; one git add -A commits an 11 MB binary"
    fail=1
  elif (cd "$R" && bash tests/dashboard-copies-in-sync.sh >/dev/null 2>&1); then
    echo "  ok: a gitignored build artefact does not fail the gate"
  else
    echo "FAIL: a gitignored build artefact failed the gate — it would fail for anyone who runs go build"
    fail=1
  fi
  cleanup_artefact
fi

[ $fail -eq 0 ] || { echo "TEST FAIL: the sync gate does not catch every drift"; exit 1; }
echo "TEST PASS: the sync gate catches every planted drift"
