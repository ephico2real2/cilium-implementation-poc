#!/usr/bin/env bash
# test: scripts/demo46-colima-e2e.sh exits non-zero when check.sh fails.
#
# Step 6 runs check.sh through scripts/record.sh so the transcript carries the
# verdict. record.sh exits 0 unless RECORD_STRICT=1 — by design, because demos
# here prove things by failing and it must not abort a caller uninvited — so
# without the flag a failing check was recorded and the script still returned
# 0. Measured on the commit that introduced it: a check stub exiting 1 left
# the e2e at rc=0, and with --no-gates nothing else would have noticed.
#
# The SCRIPT is run, not a line grepped out of it: a line-level test passed
# with an `rc=0` reset placed after step 6, because it never saw the script's
# exit. The script is copied into a scratch tree whose lab steps (step 1
# fabric-colima-up.sh, step 3 apply.sh) are stubs that succeed and whose
# check.sh fails; record.sh and fabric-colima-lib.sh are the real ones. With
# --no-cluster --no-gates those are the only steps, so the exit code measured
# is the one a failing check produces.
#   usage: bash tests/demo46-colima-e2e-check-rc.sh   (no lab needed)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/demos/46-bgp-fabric-colima" "$T/tests"
cp "$R/scripts/demo46-colima-e2e.sh" "$R/scripts/record.sh" "$R/scripts/fabric-colima-lib.sh" "$T/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/scripts/fabric-colima-up.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/demos/46-bgp-fabric-colima/apply.sh"
printf '#!/usr/bin/env bash\necho "  FAIL   stub row"\necho "demo 46-colima check: 1 FAIL"\nexit 1\n' \
  > "$T/demos/46-bgp-fabric-colima/check.sh"
chmod +x "$T"/scripts/*.sh "$T"/demos/46-bgp-fabric-colima/*.sh

# CTX is the lib's context gate; the default passes it without a daemon call.
# FABRIC_TRANSCRIPT unset so the script writes where apply.sh does.
out=$(cd "$T" && env -u FABRIC_TRANSCRIPT -u RECORD_STRICT CTX=colima-bgp-fabric \
  bash scripts/demo46-colima-e2e.sh --no-cluster --no-gates 2>&1)
rc=$?

tx="$T/demos/46-bgp-fabric-colima/output/transcript.txt"
if ! grep -q '^\[exit code: 1\]$' "$tx" 2>/dev/null; then
  echo "TEST FAIL: the transcript does not record the check's exit code"
  printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
  exit 1
fi
if [ "$rc" -eq 0 ]; then
  echo "TEST FAIL: a failing check.sh left the e2e at rc=0 (want non-zero)"
  printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
  exit 1
fi
echo "TEST PASS: a failing check.sh fails the e2e (rc=$rc) and the transcript records it"
