#!/usr/bin/env bash
# Usage: test_recap_counts.sh <demo dir>
# The check counts RECAP.md quotes must be the PASS lines of the recorded run
# (output/transcript.txt): phases 1 to 3, and the whole run.
set -u
t="$1/output/transcript.txt"
phases="$(awk '/^==== Check phases 1-3/{on=1; next} /^==== /{on=0} on' "${t}" | grep -c '^PASS')"
total="$(grep -c '^PASS' "${t}")"
got_phases="$(sed -n 's/^Result: phases 1 to 3, \([0-9]*\) checks.*/\1/p' "$1/RECAP.md")"
got_total="$(sed -n 's/^Result: [0-9]* min [0-9]* s; \([0-9]*\) checks pass.*/\1/p' "$1/RECAP.md")"
echo "phases 1-3: transcript ${phases}, RECAP ${got_phases:-none}; whole run: transcript ${total}, RECAP ${got_total:-none}"
[ "${phases}" = "${got_phases}" ] && [ "${total}" = "${got_total}" ]
