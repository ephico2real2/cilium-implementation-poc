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
#   fabric-agent-mgmt-input.sh   execs into live containers
#   fabric-agent-allowlist.sh    builds and runs a container
#   walk46-colima-signal.mjs     drives the live page
#
# fabric-up-converge.sh is NOT in this list: it is stub-based and needs no
# lab. It had been failing for months against a curl stub frozen at an older
# /api/state, which read as "needs a live :8088" and kept it out of every
# sweep. Fixing the stub put it back in reach of this one.
SKIP="fabric-agent-mgmt-input.sh fabric-agent-allowlist.sh walk46-colima-signal.mjs"
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
  # Each gate runs with the fabric variables cleared. They are inputs to the
  # scripts under test — CTX picks the Docker context, FABRIC_PROJECT the
  # compose project — so a caller that happens to have one set changes what the
  # gate measures. Measured 2026-09-23: a CI job with CTX=default in its
  # environment failed three colima gates that pass on a laptop, because
  # check.sh's context gate then refused and the rows it produced were not the
  # rows the gate was reading.
  if out=$(env -u CTX -u FABRIC_ANY_CONTEXT -u FABRIC_PROJECT -u FABRIC_ROOT \
             -u FABRIC_DASHBOARD_PORT -u FABRIC_IMAGE_SOURCE -u BGP_FABRIC_DIR \
             -u FABRIC_ROUTER_IMAGE -u FABRIC_DASHBOARD_IMAGE -u FABRIC_REBUILD \
             "${cmd[@]}" 2>&1); then
    printf '  PASS  %s\n' "$t"
  else
    printf '  FAIL  %s\n' "$t"
    printf '%s\n' "$out" | tail -6 | sed 's/^/          /'
    fails=$((fails + 1))
  fi
done
printf '\ndemo-46 gates: %d run, %d FAIL\n' "$ran" "$fails"
exit "$fails"
