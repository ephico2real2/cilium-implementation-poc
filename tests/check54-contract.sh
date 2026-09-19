#!/usr/bin/env bash
# test: demo 54 check.sh / apply.sh contract (PATH-stub).
#   (a) a dead kubectl produces FAIL rows (never PASS) and exit ≠ 0
#   (b) the gRPC rows FAIL on {"status":"NOT_SERVING"}
#   (c) no `-k`/`-sk` and no `|| echo 000` in apply.sh or check.sh
#   (d) a kubectl that answers every jsonpath with "True" does not PASS the
#       kube-vip DS row (ready must be N/N, N ≥ 1)
#   (e) the eth0 rows PASS only on the node whose MAC answered the ARP probe:
#       a stale /32 on the other node is a FAIL, and the /orders row prints no
#       Python traceback when the body is not JSON
#   Codex five bad-input predicates (garbage ds_out, rc=18 with good headers,
#   .100/24): each must evaluate False; the valid counterparts True.
# usage: bash tests/check54-contract.sh   (exit 0 = test passes)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/54-eg-poc1-kube-vip/check.sh
APPLY=$R/demos/54-eg-poc1-kube-vip/apply.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/54-eg-poc1-kube-vip"
cp "$CHECK" "$T/repo/demos/54-eg-poc1-kube-vip/check.sh"
cp "$APPLY" "$T/repo/demos/54-eg-poc1-kube-vip/apply.sh"

printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 000\nexit 7\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"status":"NOT_SERVING"}\n'"'"'\nexit 0\n' > "$T/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/kind"
chmod +x "$T/bin/"*

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/54-eg-poc1-kube-vip/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}

if printf '%s\n' "$out" | grep -qE '^  PASS'; then
  echo "TEST FAIL: a dead kubectl produced a PASS row"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out" | grep -qE '^  FAIL' \
  || { echo "TEST FAIL: dead kubectl — no FAIL rows"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: dead kubectl — check.sh exited 0"; exit 1; }

printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC h2c' \
  || { echo "TEST FAIL: gRPC h2c FAIL row missing on NOT_SERVING"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC h2c'; then
  echo "TEST FAIL: NOT_SERVING was accepted as SERVING"
  exit 1
fi

if grep -nE -- '-sk|[[:space:]]-k[[:space:]]|[[:space:]]-k"' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry a skip-verify flag"
  exit 1
fi
if grep -nF '|| echo 000' "$APPLY" "$CHECK"; then
  echo "TEST FAIL: apply.sh/check.sh still carry || echo 000"
  exit 1
fi

# (d) "True" for every jsonpath: the DS row must not read ready=True as ready
printf '#!/usr/bin/env bash\nprintf True\n' > "$T/bin/kubectl"
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/54-eg-poc1-kube-vip/check.sh 2>/dev/null)
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+kube-vip DS ready'; then
  echo "TEST FAIL: kube-vip DS row PASSed on ready=True (want N/N)"
  printf '%s\n' "$out" | grep 'kube-vip DS ready'
  exit 1
fi

# (e) ARP answered by the worker's MAC, VIPs present only on the control-plane's eth0
printf '#!/usr/bin/env bash\nprintf "eg-poc1-control-plane\\neg-poc1-worker\\n"\n' > "$T/bin/kind"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *arping*) for i in 1 2 3; do echo "Unicast reply from ${@: -1} [fa:1f:d6:0f:1e:ae] 0.01ms"; done ;;
  "inspect -f "*"eg-poc1-worker") echo "fa:1f:d6:0f:1e:ae" ;;
  "inspect -f "*"eg-poc1-control-plane") echo "e6:61:1d:ac:15:3a" ;;
  "exec eg-poc1-control-plane ip -4 addr show eth0")
    printf '    inet 172.19.0.2/16 brd 172.19.255.255 scope global eth0\n    inet 172.19.255.100/32 scope global deprecated eth0\n    inet 172.19.255.101/32 scope global deprecated eth0\n' ;;
  "exec eg-poc1-worker ip -4 addr show eth0")
    printf '    inet 172.19.0.3/16 brd 172.19.255.255 scope global eth0\n' ;;
  *grpcurl*) echo '{"status":"SERVING"}' ;;
esac
STUB
chmod +x "$T/bin/"*
err=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/54-eg-poc1-kube-vip/check.sh 2>&1 >"$T/out.e")
out=$(cat "$T/out.e")
if printf '%s\n' "$out" | grep -Eq "PASS[[:space:]]+VIP 172\.19\.255\.10[01] on"; then
  echo "TEST FAIL: an eth0 row PASSed on a node that did not answer the ARP probe"
  printf '%s\n' "$out" | grep 'VIP 172'
  exit 1
fi
printf '%s\n' "$out" | grep -Eq "FAIL[[:space:]]+VIP 172\.19\.255\.100 on" \
  || { echo "TEST FAIL: no FAIL row for the stale .100 /32"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$err" | grep -q 'Traceback'; then
  echo "TEST FAIL: check.sh leaked a Python traceback on a non-JSON /orders body"
  exit 1
fi

# Codex five bad-input predicates — extract from check.sh and evaluate under bash
python3 - "$CHECK" <<'PY'
import pathlib, subprocess, sys

source = pathlib.Path(sys.argv[1]).read_text()

def predicate(prefix, marker):
    matches = [
        line.strip() for line in source.splitlines()
        if line.strip().startswith(prefix) and marker in line
    ]
    assert len(matches) == 1, matches
    return matches[0][len(prefix):].removesuffix("; then")

def function_predicate(name):
    body = source.split(name + "() {", 1)[1].split("\n}", 1)[0]
    matches = [
        line.strip() for line in body.splitlines()
        if line.strip().startswith("if ") and '"$code"' in line
    ]
    assert len(matches) == 1, matches
    return matches[0][3:].removesuffix("; then")

cases = [
    (
        predicate("elif ", '"$ds_out"'),
        [
            ("ds_out=garbage", False),
            ("ds_out=0/0", False),
            ("ds_out=1/2", False),
            ("ds_out=2/2", True),
        ],
    ),
    (
        function_predicate("http_door"),
        [
            ("rc=18; code=200; served=eg-poc1", False),
            ("rc=0; code=200; served=eg-poc1", True),
            ("rc=0; code=404; served=eg-poc1", False),
        ],
    ),
    (
        function_predicate("https_door"),
        [
            ("rc=18; code=200", False),
            ("rc=0; code=200", True),
        ],
    ),
    (
        function_predicate("orders_door"),
        [
            ("rc=18; code=200; parse_rc=0", False),
            ("rc=0; code=200; parse_rc=1", False),
            ("rc=0; code=200; parse_rc=0", True),
        ],
    ),
    (
        predicate("if ", "/32 "),
        [
            (
                'ip=172.19.255.100; '
                'out="inet 172.19.255.100/24 scope global eth0"',
                False,
            ),
            (
                'ip=172.19.255.100; '
                'out="inet 172.19.255.100/32 scope global eth0"',
                True,
            ),
            (
                'ip=172.19.255.100; '
                'out="inet 172.19.255.101/32 scope global eth0"',
                False,
            ),
        ],
    ),
]

failures = []
for condition, inputs in cases:
    for setup, expected in inputs:
        result = subprocess.run(
            ["bash", "-c", setup + "; " + condition],
            capture_output=True,
            text=True,
        )
        actual = result.returncode == 0
        if actual != expected:
            failures.append((setup, expected, actual, condition))

if failures:
    for failure in failures:
        print("FAIL predicate:", failure[0], "expected", failure[1], "got", failure[2])
    print("%d failed assertions" % len(failures))
    sys.exit(1)
print("predicates: 0 failed assertions")
PY
pred_rc=$?
[ "$pred_rc" -eq 0 ] || { echo "TEST FAIL: Codex bad-input predicates"; exit 1; }

echo "TEST PASS: dead kubectl → FAIL (never PASS, exit ≠ 0); NOT_SERVING is FAIL; no skip-verify, no || echo 000; ready=True is not ready; eth0 rows follow the ARP responder; no traceback; Codex predicates hold"
exit 0
