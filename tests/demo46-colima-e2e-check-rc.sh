#!/usr/bin/env bash
# test: scripts/demo46-colima-e2e.sh exits non-zero when check.sh fails.
#
# Step 6 runs check.sh through scripts/record.sh so the transcript carries the
# verdict. record.sh exits 0 unless RECORD_STRICT=1 — by design, because demos
# here prove things by failing and it must not abort a caller uninvited — so
# without the flag a failing check was recorded and the script still returned
# 0. Measured on the commit that introduced it: a check stub exiting 1 left
# the e2e at rc=0, and with --no-gates nothing else would have noticed.
#   usage: bash tests/demo46-colima-e2e-check-rc.sh   (no lab needed)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)

# The script's own line, run against a stub — not a copy of it, so the test
# cannot drift from what the script does.
# shellcheck disable=SC2016  # the pattern matches the script's literal text
line=$(grep -E 'scripts/record\.sh "\$TRANSCRIPT" "\$HERE/check\.sh" \|\| rc=\$\?' \
  "$R/scripts/demo46-colima-e2e.sh" | sed 's/^[[:space:]]*//')
[ -n "$line" ] || { echo "TEST FAIL: the check line is not in scripts/demo46-colima-e2e.sh"; exit 1; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
printf '#!/usr/bin/env bash\necho "  FAIL   stub row"\necho "demo 46-colima check: 1 FAIL"\nexit 1\n' > "$T/check.sh"
chmod +x "$T/check.sh"

got=$(cd "$R" && HERE="$T" TRANSCRIPT="$T/transcript.txt" \
  bash -c "rc=0; $line; echo \"e2e rc=\$rc\"" 2>/dev/null | tail -1)

if ! grep -q '^\[exit code: 1\]$' "$T/transcript.txt" 2>/dev/null; then
  echo "TEST FAIL: the transcript does not record the check's exit code"
  exit 1
fi
if [ "$got" != "e2e rc=1" ]; then
  echo "TEST FAIL: a failing check.sh left the e2e at '$got' (want e2e rc=1)"
  exit 1
fi
echo "TEST PASS: a failing check.sh fails the e2e ($got) and the transcript records it"
