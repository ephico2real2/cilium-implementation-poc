#!/usr/bin/env bash
# test: CTX and FABRIC_COLIMA_PROFILE must name the same lab. A mismatch sends
# `colima ssh --profile <other> -- sudo …` (demo 54c step 9) and the kernel
# read at a VM this lab does not own, while every docker call still looks right.
# usage: bash tests/fabric-colima-profile-pair.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
LIB=$R/scripts/fabric-colima-lib.sh
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric-colima/fabric" "$T/repo/scripts/bootstrap"
cp "$R/demos/46-bgp-fabric-colima/check.sh" "$T/repo/demos/46-bgp-fabric-colima/check.sh"
cp "$LIB" "$T/repo/scripts/fabric-colima-lib.sh"
for f in fabric-bgp-summary.py fabric-dashboard-state.py fabric-dashboard-agree.py; do
  cp "$R/scripts/$f" "$T/repo/scripts/$f"
done
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env"
printf 'name: bgp-fabric-colima\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'context inspect'*) echo '{}'; exit 0 ;;
  *' info'*) echo ok; exit 0 ;;
  *'ps --format'*) for s in edge spine leaf1 leaf2 client0; do echo "bgp-fabric-colima-$s-1 running"; done; exit 0 ;;
  *'ps -q'*) echo cid; exit 0 ;;
  *'show bgp summary json'*) printf '{"ipv4Unicast":{"peers":{"10.200.1.3":{"state":"Established","remoteAs":65100}}}}\n'; exit 0 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"
printf '#!/usr/bin/env bash\necho "COLIMA $*" >> "$COLIMA_LOG"\nexit 1\n' > "$T/bin/colima"
chmod +x "$T/bin/colima"
: > "$T/colima.log"
rc=0
(cd "$T/repo" && env CTX=colima-bgp-fabric FABRIC_COLIMA_PROFILE=md5lab \
   PATH="$T/bin:/usr/bin:/bin" COLIMA_LOG="$T/colima.log" \
   bash demos/46-bgp-fabric-colima/check.sh >/dev/null 2>"$T/err") || rc=$?
if grep -q 'profile md5lab' "$T/colima.log"; then
  echo "TEST FAIL: CTX=colima-bgp-fabric with profile md5lab reached 'colima --profile md5lab'"
  cat "$T/colima.log"
  exit 1
fi
[ "$rc" -ne 0 ] || { echo "TEST FAIL: the mismatched pair exited 0"; exit 1; }
grep -q 'refusing' "$T/err" || { echo "TEST FAIL: the mismatched pair did not refuse"; cat "$T/err"; exit 1; }
# the matching pair still runs (it gets as far as calling colima)
: > "$T/colima.log"
(cd "$T/repo" && env CTX=colima-bgp-fabric FABRIC_COLIMA_PROFILE=bgp-fabric \
   PATH="$T/bin:/usr/bin:/bin" COLIMA_LOG="$T/colima.log" \
   bash demos/46-bgp-fabric-colima/check.sh >/dev/null 2>&1)
grep -q 'profile bgp-fabric' "$T/colima.log" \
  || { echo "TEST FAIL: the matching pair no longer reaches colima"; cat "$T/colima.log"; exit 1; }
echo "TEST PASS: CTX and FABRIC_COLIMA_PROFILE must name the same lab; a mismatch refuses before any colima call"
exit 0
