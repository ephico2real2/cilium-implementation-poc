#!/usr/bin/env bash
# test: demo 52 check.sh / apply.sh contract (PATH-stub).
#   (a) a dead kubectl produces FAIL rows (never PASS) and exit ≠ 0
#   (b) the Health row FAILs on {"status":"NOT_SERVING"}
#   (c) a stub that answers {"version":"v1"} for GetOrder is FAIL
#   (d) no `-k`/`-sk` and no `|| echo 000` in apply.sh or check.sh
#   (e) T8b FAILs on Code: Unimplemented with a non-empty Message
#   (f) T8a FAILs on Code: Unimplemented without the "unknown method" message
# usage: bash tests/check52-contract.sh   (exit 0 = test passes)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/52-eg-poc2-metallb/check.sh
APPLY=$R/demos/52-eg-poc2-metallb/apply.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/52-eg-poc2-metallb"
cp "$CHECK" "$T/repo/demos/52-eg-poc2-metallb/check.sh"
cp "$APPLY" "$T/repo/demos/52-eg-poc2-metallb/apply.sh"

printf '#!/usr/bin/env bash\necho "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1\n' > "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 000\nexit 7\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"status":"NOT_SERVING"}\n'"'"'\nexit 0\n' > "$T/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/kind"
chmod +x "$T/bin/"*

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/52-eg-poc2-metallb/check.sh 2>/dev/null) || rc=$?
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

printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC Health' \
  || { echo "TEST FAIL: gRPC Health FAIL row missing on NOT_SERVING"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC Health'; then
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

# GetOrder must require version v2 — a stub that answers v1 is FAIL
printf '#!/usr/bin/env bash\nprintf "eg-poc2-control-plane\\neg-poc2-worker\\n"\n' > "$T/bin/kind"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *arping*) for i in 1 2 3; do echo "Unicast reply from ${@: -1} [aa:bb:cc:dd:ee:ff] 0.01ms"; done ;;
  "inspect -f "*) echo "aa:bb:cc:dd:ee:ff" ;;
  "exec "*ip*)
    printf '    inet 172.19.0.3/16 brd 172.19.255.255 scope global eth0\n' ;;
  *)
    echo '{"version":"v1"}' ;;
esac
STUB
chmod +x "$T/bin/"*
printf '#!/usr/bin/env bash\nprintf True\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/52-eg-poc2-metallb/check.sh 2>/dev/null) || true
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC GetOrder v2' \
  || { echo "TEST FAIL: GetOrder row did not FAIL on {\"version\":\"v1\"}"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC GetOrder v2'; then
  echo "TEST FAIL: GetOrder PASSed on version v1"
  exit 1
fi

# T8a requires "unknown method"; T8b requires an empty Message line
printf '#!/usr/bin/env bash\nprintf "eg-poc2-control-plane\\neg-poc2-worker\\n"\n' > "$T/bin/kind"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *arping*) for i in 1 2 3; do echo "Unicast reply from ${@: -1} [aa:bb:cc:dd:ee:ff] 0.01ms"; done ;;
  "inspect -f "*) echo "aa:bb:cc:dd:ee:ff" ;;
  "exec "*ip*)
    printf '    inet 172.19.0.3/16 brd 172.19.255.255 scope global eth0\n' ;;
  *nope.proto*|*Nope/Do*)
    printf 'Code: Unimplemented\nMessage: not empty\n' ;;
  *probe.proto*|*NoSuchMethod*)
    printf 'Code: Unimplemented\nMessage:\n' ;;
  *)
    echo '{"version":"v1"}' ;;
esac
STUB
chmod +x "$T/bin/"*
printf '#!/usr/bin/env bash\nprintf True\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/52-eg-poc2-metallb/check.sh 2>/dev/null) || true
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC unrouted service Unimplemented' \
  || { echo "TEST FAIL: T8b row did not FAIL on Unimplemented with a non-empty Message"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC unrouted service Unimplemented'; then
  echo "TEST FAIL: T8b PASSed on a non-empty Message"
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+gRPC NoSuchMethod Unimplemented' \
  || { echo "TEST FAIL: T8a row did not FAIL on Unimplemented without unknown method"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+gRPC NoSuchMethod Unimplemented'; then
  echo "TEST FAIL: T8a PASSed without the unknown method message"
  exit 1
fi

echo "TEST PASS: dead kubectl → FAIL (never PASS, exit ≠ 0); NOT_SERVING is FAIL; GetOrder v1 is FAIL; T8a without unknown method is FAIL; T8b with a non-empty Message is FAIL; no skip-verify, no || echo 000"
exit 0
