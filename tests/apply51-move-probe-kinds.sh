#!/usr/bin/env bash
# test: measure_move must record curl's exit code per sample and print a fail_kinds
# breakdown (timeout vs refused vs answered-non-200), and must not double the 000.
# The function runs under set -euo pipefail as apply.sh does: a bare
# code=$(curl …) assignment kills the probe subshell on the first failed probe.
# usage: bash tests/apply51-move-probe-kinds.sh demos/51-eg-kube-vip/apply.sh   (exit 0 = test passes)
set -uo pipefail
APPLY=${1:?apply.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/scripts"
# extract measure_move (the function under test) from apply.sh
awk '/^measure_move\(\) \{/,/^}$/' "$APPLY" > "$T/measure_move.sh"
grep -q 'measure_move()' "$T/measure_move.sh" || { echo "TEST FAIL: measure_move not found"; exit 1; }
# a curl that is refused (000, exit 7) 4 times, times out (000, exit 28) 3 times, then 200
cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
n=\$(cat "$T/n" 2>/dev/null || echo 0); echo \$((n+1)) > "$T/n"
if [ "\$n" -lt 4 ]; then printf 000; exit 7; fi
if [ "\$n" -lt 7 ]; then printf 000; exit 28; fi
printf 200; exit 0
STUB
printf '#!/usr/bin/env bash\necho "Unicast reply from 172.19.255.16 [aa:bb:cc:dd:ee:ff] 0.1ms"\n' > "$T/bin/docker"
printf '#!/usr/bin/env bash\nsleep 4\n' > "$T/repo/scripts/eg-vip-move.sh"
chmod +x "$T/bin/"* "$T/repo/scripts/eg-vip-move.sh"
out=$(cd "$T/repo" && CA=/dev/null PATH="$T/bin:/usr/bin:/bin" bash -c "set -euo pipefail; . '$T/measure_move.sh'; measure_move eg2" 2>&1)
printf '%s\n' "$out" | grep -q 'VIP move eg2: samples=' || { echo "TEST FAIL: no summary"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'fail_kinds=000/curl28x3 000/curl7x4' || { echo "TEST FAIL: no per-kind breakdown (timeout vs refused)"; printf '%s\n' "$out" | grep 'VIP move'; exit 1; }
echo "TEST PASS: $(printf '%s\n' "$out" | grep fail_kinds)"
