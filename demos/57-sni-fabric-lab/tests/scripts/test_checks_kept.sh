#!/usr/bin/env bash
# Usage: test_checks_kept.sh <previous transcript> <new transcript>
# "Nothing existing stops": every check that passed in the previous recorded run passes in the
# new one, so the count of checks only grows. A check is known by verify.sh's name field
# (`PASS  %-46s %s`: columns 7 to 52), which holds the name and never the measured value.
set -u
names() { grep -E '^PASS  ' "$1" | cut -c7-52 | sed 's/ *$//' | sort -u; }
before="$(names "$1")"
after="$(names "$2")"
missing="$(comm -23 <(echo "${before}") <(echo "${after}"))"
echo "checks passing: $(grep -c . <<<"${before}") before, $(grep -c . <<<"${after}") after"
if [ -z "${before}" ] || [ -n "${missing}" ]; then
  mapfile -t lines <<<"${missing:-(the previous transcript has no PASS line)}"
  echo "no longer passing:"
  printf '  %s\n' "${lines[@]}"
  exit 1
fi
