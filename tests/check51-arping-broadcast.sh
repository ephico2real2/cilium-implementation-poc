#!/usr/bin/env bash
# test: the ARP responder rows must keep every probe a broadcast (arping -b); without
# it busybox arping unicasts probes 2 and 3 to the first responder (tcpdump-measured).
# usage: bash tests/check51-arping-broadcast.sh demos/51-eg-kube-vip/check.sh   (exit 0 = test passes)
set -uo pipefail
CHECK=${1:?check.sh path}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/51-eg-kube-vip"
cp "$CHECK" "$T/repo/demos/51-eg-kube-vip/check.sh"
printf '#!/usr/bin/env bash\necho "Error from server (NotFound)" >&2; exit 1\n' > "$T/bin/kubectl"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/curl"
cat > "$T/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$*" in *arping*) echo "docker \$*" >> "$T/docker.log";; esac
exit 1
STUB
chmod +x "$T/bin/"*
(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/51-eg-kube-vip/check.sh >/dev/null 2>&1)
n=$(grep -c 'arping' "$T/docker.log" 2>/dev/null || true)
[ "$n" -eq 3 ] || { echo "TEST FAIL: expected 3 arping calls, saw $n"; exit 1; }
nb=$(grep -c 'arping -b ' "$T/docker.log" || true)
[ "$nb" -eq 3 ] || { echo "TEST FAIL: $nb of 3 arping calls carry -b"; exit 1; }
echo "TEST PASS: all 3 arping calls broadcast every probe (-b)"
