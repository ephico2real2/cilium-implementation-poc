#!/usr/bin/env bash
# test: demo 52's cleanup.sh (1) waits for the Envoy door Services to be GONE before
# `helm uninstall metallb` (the Services carry service.kubernetes.io/load-balancer-cleanup,
# which only MetalLB clears — demo 54 review A3), and (2) empties the pools BEFORE the
# uninstall: chart 0.16.0 templates its nine CRDs (`helm show crds`: none; `helm get
# manifest`: 9, no helm.sh/resource-policy keep — measured 2026-09-19 on kind-eg-poc2), so
# the uninstall removes them, and `kubectl delete ipaddresspool --all --ignore-not-found`
# against a type the server no longer has is exit 1 ("the server doesn't have a resource
# type"), which `set -e` turns into an abort before metallb-system is deleted.
# PATH-stub: kubectl/helm log their args; kubectl answers like the server would after the
# uninstall (the metallb.io types are gone); a second run (nothing installed) must also pass.
# usage: bash tests/cleanup52-order.sh [demos/52-eg-poc2-metallb/cleanup.sh]   (exit 0 = pass)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CLEANUP=${1:-$R/demos/52-eg-poc2-metallb/cleanup.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/52-eg-poc2-metallb"
cp "$CLEANUP" "$T/repo/demos/52-eg-poc2-metallb/cleanup.sh"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$STUB_LOG"
# the metallb.io CRDs exist until `helm uninstall metallb` has run (STUB_CRD=0 models
# a cluster where MetalLB was never installed / a second cleanup run)
crd_present() {
  [ "${STUB_CRD:-1}" = 1 ] && ! grep -q '^helm uninstall metallb' "$STUB_LOG"
}
case "$*" in
  *"get crd ipaddresspools.metallb.io"*)
    crd_present && { echo customresourcedefinition.apiextensions.k8s.io/ipaddresspools.metallb.io; exit 0; }
    echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "ipaddresspools.metallb.io" not found' >&2; exit 1 ;;
  *"delete ipaddresspool"*|*"delete l2advertisement"*)
    crd_present && exit 0
    echo 'error: the server doesn'"'"'t have a resource type "ipaddresspool"' >&2; exit 1 ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nprintf "helm %%s\\n" "$*" >> "$STUB_LOG"\n' > "$T/bin/helm"
chmod +x "$T/bin/kubectl" "$T/bin/helm"

run_cleanup() { # STUB_CRD
  : > "$T/log"
  (cd "$T/repo" && STUB_LOG="$T/log" STUB_CRD="$1" PATH="$T/bin:/usr/bin:/bin" bash demos/52-eg-poc2-metallb/cleanup.sh >/dev/null 2>&1)
}

run_cleanup 1; rc=$?
[ "$rc" -eq 0 ] || { echo "TEST FAIL: cleanup.sh exit $rc with MetalLB installed (pools deleted after the CRDs went?)"; cat "$T/log"; exit 1; }
gw_line=$(grep -n -- '-n shop delete gateway' "$T/log" | head -1 | cut -d: -f1)
wait_line=$(grep -nE -- '-n envoy-gateway-system wait svc .*--for=delete' "$T/log" | head -1 | cut -d: -f1)
pool_line=$(grep -nE -- 'delete (ipaddresspool|l2advertisement)' "$T/log" | tail -1 | cut -d: -f1)
helm_line=$(grep -n '^helm uninstall metallb' "$T/log" | head -1 | cut -d: -f1)
ns_line=$(grep -n -- 'delete ns metallb-system' "$T/log" | head -1 | cut -d: -f1)
for v in gw_line wait_line pool_line helm_line ns_line; do
  [ -n "${!v}" ] || { echo "TEST FAIL: $v missing from the log"; cat "$T/log"; exit 1; }
done
if ! { [ "$gw_line" -lt "$wait_line" ] && [ "$wait_line" -lt "$helm_line" ]; }; then
  echo "TEST FAIL: order is gateway@$gw_line wait@$wait_line helm@$helm_line (want gateway < wait < helm uninstall)"; cat "$T/log"; exit 1
fi
if [ "$pool_line" -gt "$helm_line" ]; then
  echo "TEST FAIL: pools/L2Advertisement deleted at line $pool_line, after helm uninstall at $helm_line (the CRDs are gone by then)"; cat "$T/log"; exit 1
fi
[ "$ns_line" -gt "$helm_line" ] || { echo "TEST FAIL: metallb-system deleted before helm uninstall"; cat "$T/log"; exit 1; }
grep -qE -- 'wait svc .*--timeout=' "$T/log" || { echo "TEST FAIL: the wait has no --timeout"; exit 1; }

# second run: MetalLB already gone (no CRDs) — cleanup must still exit 0 and delete the namespace
run_cleanup 0; rc=$?
[ "$rc" -eq 0 ] || { echo "TEST FAIL: cleanup.sh exit $rc on a cluster without MetalLB (not idempotent)"; cat "$T/log"; exit 1; }
grep -q -- 'delete ns metallb-system' "$T/log" || { echo "TEST FAIL: second run never reached delete ns metallb-system"; cat "$T/log"; exit 1; }

echo "TEST PASS: cleanup.sh deletes the Gateways, waits for their Services, empties the pools while the CRDs exist, uninstalls MetalLB, deletes metallb-system; idempotent"
exit 0
