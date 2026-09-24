#!/usr/bin/env bash
# run-demo46-gates.sh — every demo-46 gate that needs no running fabric.
#
# The review records say "every test under tests/*46*, tests/fabric-*.sh,
# tests/demo46-claims.py, readme46-verbatim.py", which is a list a person has
# to reassemble by hand each time and which quietly grew. This is that list,
# minus the four that need a lab or a second daemon — those are named below
# with the reason, so a reader can see what is NOT covered here rather than
# assuming the set is complete.
#
#   usage: bash tests/run-demo46-gates.sh          (exit = number that failed)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Needs a running fabric or a second daemon, so it belongs to a lab run:
#   fabric-up-converge.sh        talks to a live :8088
#   fabric-agent-mgmt-input.sh   execs into live containers
#   fabric-agent-allowlist.sh    builds and runs a container
#   walk46-colima-signal.mjs     drives the live page
SKIP="fabric-up-converge.sh fabric-agent-mgmt-input.sh fabric-agent-allowlist.sh walk46-colima-signal.mjs"
# And this file. `tests/*46*.sh` matches run-demo46-gates.sh itself — measured
# the hard way: the first run of it forked itself until the machine was full.
SKIP="$SKIP $(basename "$0")"

fails=0
ran=0
for t in tests/*46*.sh tests/*46*.py tests/fabric-*.sh tests/bgp-fabric-*.sh tests/dashboard-*.sh; do
  [ -f "$t" ] || continue
  case " $SKIP " in *" $(basename "$t") "*) continue ;; esac
  case "$t" in *.py) cmd=(python3 "$t") ;; *) cmd=(bash "$t") ;; esac
  ran=$((ran + 1))
  if out=$("${cmd[@]}" 2>&1); then
    printf '  PASS  %s\n' "$t"
  else
    printf '  FAIL  %s\n' "$t"
    printf '%s\n' "$out" | tail -6 | sed 's/^/          /'
    fails=$((fails + 1))
  fi
done
printf '\ndemo-46 gates: %d run, %d FAIL\n' "$ran" "$fails"
exit "$fails"
