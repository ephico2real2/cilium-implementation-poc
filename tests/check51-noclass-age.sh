#!/usr/bin/env bash
# test: "probe-noclass stays pending" must not PASS for a Service created seconds ago —
# a fresh class-less Service is <pending> whatever the class filter does. It must PASS
# for one that has been <pending> and unclaimed for ≥ 30 s, and FAIL for a 120 s old
# Service that still carries kube-vip's claim marks (phase 0 first measurement).
# usage: bash tests/check51-noclass-age.sh demos/51-eg-kube-vip/check.sh   (exit 0 = test passes)
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/51-eg-kube-vip"
cp "$CHECK" "$T/repo/demos/51-eg-kube-vip/check.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/docker"; cp "$T/bin/docker" "$T/bin/curl"; chmod +x "$T/bin/"*
stub() { # created-timestamp [impl] [ann] → a kubectl that serves probe-noclass and errors on the rest
  local created=$1 impl=${2:-} ann=${3:-}
  cat > "$T/bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"svc probe-noclass"*"spec.type"*) echo LoadBalancer ;;
  *"svc probe-noclass"*"creationTimestamp"*) echo "$created" ;;
  *"svc probe-noclass"*"implementation"*) echo "$impl" ;;
  *"svc probe-noclass"*"loadbalancerIPs"*) echo "$ann" ;;
  *"svc probe-noclass"*) echo -n "" ;;
  *) echo "Error from server (NotFound)" >&2; exit 1 ;;
esac
STUB
  chmod +x "$T/bin/kubectl"
}
run() { (cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/51-eg-kube-vip/check.sh 2>/dev/null); }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
stub "$now"
out=$(run)
if printf '%s\n' "$out" | grep -qE '^  PASS +eg1 probe-noclass stays pending'; then echo "TEST FAIL: a seconds-old Service PASSed 'stays pending'"; exit 1; fi
stub "$old"
out=$(run)
printf '%s\n' "$out" | grep -qE '^  PASS +eg1 probe-noclass stays pending' || { echo "TEST FAIL: a 120 s old pending Service did not PASS"; exit 1; }
# Grok's third case: 120 s old but claimed (implementation=kube-vip + loadbalancerIPs)
stub "$old" kube-vip 172.19.255.200
out=$(run)
if printf '%s\n' "$out" | grep -qE '^  PASS +eg1 probe-noclass stays pending'; then echo "TEST FAIL: a claimed-but-pending 120 s Service PASSed"; exit 1; fi
printf '%s\n' "$out" | grep -qE '^  FAIL +eg1 probe-noclass stays pending' || { echo "TEST FAIL: claimed-but-pending row missing"; exit 1; }
echo "TEST PASS: fresh Service -> FAIL, 120 s pending -> PASS, 120 s claimed -> FAIL"
