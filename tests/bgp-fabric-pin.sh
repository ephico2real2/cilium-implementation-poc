#!/usr/bin/env bash
# test: scripts/bgp-fabric-fetch.sh either hands over the pinned tree or fails
# loudly — it never hands over a tree that is not the pinned commit.
#
# A pin whose fetch can succeed with edited code is not a pin. The cases are
# the ones that actually happen: a tree left at an earlier pin with an edit or
# an extra file in it, a tag moved upstream, a run killed between the clone
# and the checkout, a CDPATH in the environment.
#
# The real repository is never touched: a fixture upstream with TWO commits
# and a fixture lab are built in a temp dir, and the script under test is the
# repository's own copy.
#   usage: bash tests/bgp-fabric-pin.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git_ () { git -c user.email=t@t -c user.name=t "$@"; }

# --- fixture upstream: two commits, one file identical in both -------------
mkdir -p "$T/up/fabric" "$T/up/dashboard" "$T/up/frr-agent" "$T/up/scripts"
printf 'v1\n'     > "$T/up/dashboard/file.go"
printf 'shared\n' > "$T/up/dashboard/shared.go"
printf 'x\n'      > "$T/up/fabric/compose.yaml"
printf 'x\n'      > "$T/up/frr-agent/Containerfile"
git_ -C "$T/up" init -q .
git_ -C "$T/up" add -A; git_ -C "$T/up" commit -qm one
OLD=$(git -C "$T/up" rev-parse HEAD)
printf 'v2\n' > "$T/up/dashboard/file.go"
git_ -C "$T/up" add -A; git_ -C "$T/up" commit -qm two
PIN=$(git -C "$T/up" rev-parse HEAD)
git_ -C "$T/up" tag -f v0.1.0 "$PIN" >/dev/null

# --- fixture lab: the repository's own fetch script, a generated pin -------
mkdir -p "$T/lab/scripts"
cp "$R/scripts/bgp-fabric-fetch.sh" "$T/lab/scripts/" \
  || { echo "TEST FAIL: scripts/bgp-fabric-fetch.sh does not exist"; exit 1; }
cat > "$T/lab/scripts/bgp-fabric.env" <<EOF
BGP_FABRIC_REPO=$T/up
BGP_FABRIC_TAG=v0.1.0
BGP_FABRIC_COMMIT=$PIN
EOF
V="$T/lab/vendor/bgp-fabric"

fail=0
bad() { echo "FAIL: $*"; fail=1; }
fetch() { (cd "$T/lab" && bash scripts/bgp-fabric-fetch.sh 2>"$T/err"); }
reset_to() { # sha — a clean vendor tree at that commit
  git -C "$V" fetch -q --force --tags origin
  git -C "$V" checkout -q --force --detach "$1"
  git -C "$V" clean -qfdx
}

# 1. a fresh clone lands on the pin, and prints exactly one path
out=$(fetch); rc=$?
[ $rc -eq 0 ] || bad "a fresh fetch exited $rc: $(cat "$T/err")"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || bad "stdout was not one line: [$out]"
[ "$(git -C "$V" rev-parse HEAD)" = "$PIN" ] || bad "a fresh fetch did not land on the pin"

# 2. idempotent
out=$(fetch) || bad "the second fetch exited non-zero: $(cat "$T/err")"
[ "$out" = "$T/lab/vendor/bgp-fabric" ] || bad "the second fetch printed [$out]"

# 3. an edit to the tree AT the pin is refused
echo hacked >> "$V/dashboard/file.go"
fetch >/dev/null && bad "an edited tree at the pin was accepted"
grep -q 'local modifications' "$T/err" || bad "the refusal did not say what was wrong: $(cat "$T/err")"

# 4. an edit carried across a PIN BUMP is refused.
#    `git checkout` keeps a modified file whenever both commits hold it
#    identically, so the tree ends at the pinned sha with unpinned code in it.
reset_to "$OLD"
echo "BACKDOOR" >> "$V/dashboard/shared.go"
out=$(fetch); rc=$?
if [ $rc -eq 0 ]; then
  bad "a pin bump carried an edit across and reported success: $(cat "$T/err")"
  grep -q BACKDOOR "$V/dashboard/shared.go" && echo "        (the edit is still in the tree it handed over)"
fi

# 5. an untracked file that survives a pin bump is refused — it is compiled
#    into the image exactly like a tracked one
reset_to "$OLD"
printf 'package evil\n' > "$V/dashboard/backdoor.go"
fetch >/dev/null && bad "a pin bump carried an untracked file across and reported success"

# 6. a tag moved upstream must not break the fetch, and must never fail in
#    silence: the pin is a commit and does not depend on the tag at all
reset_to "$PIN"
git -C "$V" fetch -q --force --tags origin
git_ -C "$T/up" tag -f v0.1.0 "$OLD" >/dev/null
reset_to "$OLD" 2>/dev/null
git_ -C "$T/up" tag -f v0.1.0 "$PIN" >/dev/null   # upstream moves it back
git -C "$V" checkout -q --force --detach "$OLD"; git -C "$V" clean -qfdx
out=$(fetch); rc=$?
if [ $rc -ne 0 ]; then
  [ -s "$T/err" ] || bad "a moved upstream tag failed the fetch in total silence (exit $rc)"
  bad "a moved upstream tag broke the fetch of a commit pin: $(cat "$T/err")"
fi

# 7. a run killed between the clone and the checkout recovers by itself
rm -rf "$T/lab/vendor"
git clone -q --no-checkout "$T/up" "$V"
out=$(fetch); rc=$?
[ $rc -eq 0 ] || bad "an interrupted clone did not recover (exit $rc): $(cat "$T/err")"
[ -f "$V/dashboard/file.go" ] || bad "an interrupted clone left the tree unmaterialised"

# 8. CDPATH must not put a second line — or a decoy tree — on stdout
reset_to "$OLD"
mkdir -p "$T/decoy/vendor/bgp-fabric"
out=$(cd "$T/lab" && CDPATH="$T/decoy" bash scripts/bgp-fabric-fetch.sh 2>/dev/null)
[ "$out" = "$T/lab/vendor/bgp-fabric" ] || bad "with CDPATH set the script printed [$out]"

[ $fail -eq 0 ] || { echo "TEST FAIL: the pin can hand over a tree that is not the pinned commit"; exit 1; }
echo "TEST PASS: bgp-fabric-fetch hands over the pinned tree or fails loudly"
