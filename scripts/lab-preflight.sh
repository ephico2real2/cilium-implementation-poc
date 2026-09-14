#!/usr/bin/env bash
# lab-preflight.sh — measure THIS machine before anything is created, and say what the lab can and cannot run here.
#
# One script for a GitHub runner, a Linux laptop and a MacBook (Intel or Apple silicon): the same questions, the answers
# read from the machine, so a difference is caught at the start and not halfway through a bring-up (enhancement 004;
# SETUP Steps 0–2). Every row names the rule it applies and where the rule comes from. Nothing here is a guess: a
# feature is "yes" only when the kernel actually created the device / exported the symbol / answered the sysctl.
#
#   scripts/lab-preflight.sh                       # the table; exit 0 whatever it finds
#   LAB_PREFLIGHT_STRICT=1 scripts/lab-preflight.sh # exit 1 when a REQUIRED row fails (lab-up.sh runs it this way)
#
# The kind cluster files and the Cilium values are the SAME on every host on purpose — one path (SETUP's, the runner's,
# the MacBook's). What differs between hosts is measured here: the kernel the nodes will share (the Docker VM's on
# macOS), the CPU architecture (the pinned node image is an OCI index with amd64 and arm64), the memory the VM was
# given, whether the host can route to the LB blocks (SETUP Step 3.5 needs the VM on a host bridge), and whether the
# docker network can carry IPv6 for the dual-stack runs.
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
NODE_IMAGE="${NODE_IMAGE:-$(grep -m1 -oE 'kindest/node:[^ ]+' clusters/ci/poc1.yaml)}"
STRICT="${LAB_PREFLIGHT_STRICT:-0}"; failed=0
os=$(uname -s); arch=$(uname -m)

row() { # <status> <what> <measured> <rule / where it comes from>   status: ok | no | warn | REQUIRED-FAIL
  printf '  %-13s %-26s %-44s %s\n' "$1" "$2" "$3" "$4"
  [ "$1" = "REQUIRED-FAIL" ] && failed=1; return 0
}
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge 7.0.12 6.8 → true

printf '\n== lab preflight on %s %s — measured, every row (rules: docs/SETUP.md Steps 0–2, Cilium %s system requirements)\n' "$os" "$arch" "$CILIUM_VERSION"
printf '  %-13s %-26s %-44s %s\n' STATUS WHAT MEASURED RULE
case "$os" in
  Darwin) row ok "host" "macOS $(sw_vers -productVersion) on $arch, $(/usr/sbin/sysctl -n hw.ncpu) CPUs, $(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 )) GiB" "the nodes run in Docker's Linux VM, not on this kernel" ;;
  Linux)  row ok "host" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") on $arch, $(nproc) CPUs, $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 )) GiB" "the nodes share THIS kernel" ;;
esac

# ---------------------------------------------------------------- Docker: answering, version, the VM's resources and kernel
if ! docker info >/dev/null 2>&1; then
  row REQUIRED-FAIL "docker" "the daemon is not answering" "SETUP Step 1.4 — start Docker (Desktop on macOS) first"
  printf '\n'; [ "$STRICT" = 1 ] && exit 1; exit 0
fi
dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null); kern=$(docker info --format '{{.KernelVersion}}' 2>/dev/null)
# a daemon that answers can still print an empty field (Desktop mid-start): default every number, or `set -u` and the
# arithmetic abort the table half-way (review of 004, C7)
raw_mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null); raw_mem=${raw_mem:-0}; dmem=$(( raw_mem / 1073741824 ))
dcpu=$(docker info --format '{{.NCPU}}' 2>/dev/null); dcpu=${dcpu:-0}
if [ "$os" = Darwin ]; then
  app=$(defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "?")
  row ok "Docker Desktop" "app $app, engine $dver" "4.89.0 ships Linux kernel v7.0.12 (release notes); 4.27.2 shipped 6.6.12"
  # the VM's shape and the two settings the lab depends on — whichever settings file this Desktop version writes
  sf=$(ls "$HOME/Library/Group Containers/group.com.docker/settings-store.json" "$HOME/Library/Group Containers/group.com.docker/settings.json" 2>/dev/null | head -1)
  if [ -n "$sf" ]; then
    keys=$(python3 - "$sf" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = ("vmtype", "virtualization", "kernelforudp", "networktype", "hostnetworking", "ipv6", "vmm")
print(", ".join(f"{k}={v}" for k, v in d.items() if any(w in k.lower() for w in want)) or "no matching keys")
PY
)
    row ok "Desktop settings" "$keys" "$(basename "$sf"): the VMM (Docker VMM vs Apple Virtualization framework) and kernelForUDP (Step 2.3b)"
  fi
else
  row ok "docker" "engine $dver" ""
fi
# the floors are measured, not chosen: the runner's 4 vCPU / 15 GiB carries clusters/ci (1+1 twice, meshed, Hubble,
# Tetragon, Cilium's 87-test suite) with ~5 GB used; the laptop's full-size clusters/ (3+2 and 1+1, seven nodes)
# were run on 16 CPUs / 16 GiB and the guide asks for ≥ 8 / 16 (SETUP Steps 0.4 and 2.3)
if [ "$dmem" -ge 16 ]; then row ok "memory for the nodes" "$dmem GiB" "≥ 16 GiB for the laptop's full-size clusters (SETUP 2.3), ≥ 8 for clusters/ci"
elif [ "$dmem" -ge 8 ]; then row warn "memory for the nodes" "$dmem GiB" "enough for clusters/ci (the runner: 5 GB used, meshed); the full-size poc1 wants 16 (SETUP 2.3)"
else row REQUIRED-FAIL "memory for the nodes" "$dmem GiB" "below 8 GiB two clusters do not fit — raise the VM (SETUP Step 2.3, docs/DOCKER-DESKTOP-RUNBOOK.md §4)"; fi
if [ "${dcpu:-0}" -ge 8 ]; then row ok "CPUs for the nodes" "$dcpu" "≥ 8 for the full-size clusters (SETUP 0.4); the runner's 4 carried clusters/ci"
elif [ "${dcpu:-0}" -ge 4 ]; then row warn "CPUs for the nodes" "$dcpu" "the measured floor for clusters/ci (the runner: 4 vCPU, connectivity test 15–23 min); the full-size clusters want 8"
else row REQUIRED-FAIL "CPUs for the nodes" "$dcpu" "below 4, two clusters with Cilium have never been measured to work — raise the VM (SETUP Step 2.3, docs/DOCKER-DESKTOP-RUNBOOK.md §4)"; fi

# ---------------------------------------------------------------- the kernel the nodes will share
kv=$(echo "$kern" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true); kv=${kv:-0}
if ver_ge "$kv" 6.8; then
  # the version is necessary, not sufficient: netkit also needs CONFIG_NETKIT — so a device is actually created
  if [ "$os" = Linux ] && [ -r "/boot/config-$(uname -r)" ]; then
    if grep -qE '^CONFIG_NETKIT=(y|m)' "/boot/config-$(uname -r)"; then row ok "netkit (kernel $kern)" "≥ 6.8 and CONFIG_NETKIT in /boot/config" "Cilium $CILIUM_VERSION system requirements: netkit ≥ 6.8 + CONFIG_NETKIT"
    else row no "netkit (kernel $kern)" "≥ 6.8 but no CONFIG_NETKIT in /boot/config" "same rule; bpf.datapathMode=netkit will be refused"; fi
  else
    # on the SAME kernel (the VM's, on macOS): the kernel's own config when it exports one (Cilium creates netkit through
    # netlink, so CONFIG_NETKIT is the fact); otherwise a device is created with the Cilium image's iproute2 (6.19 on its
    # Ubuntu 26.04 base, which knows the netkit link type — review of 004, C7)
    if docker run --rm --privileged busybox:1.36 sh -c 'zcat /proc/config.gz 2>/dev/null | grep -qE "^CONFIG_NETKIT=(y|m)"' >/dev/null 2>&1; then
      row ok "netkit (kernel $kern)" "≥ 6.8 and CONFIG_NETKIT in the VM kernel's /proc/config.gz" "Cilium $CILIUM_VERSION system requirements: netkit ≥ 6.8 + CONFIG_NETKIT"
    elif docker run --rm --privileged --net=host --entrypoint sh "quay.io/cilium/cilium:v$CILIUM_VERSION" -c 'ip link add lab-preflight-nk type netkit >/dev/null 2>&1 && ip link del lab-preflight-nk' >/dev/null 2>&1; then
      row ok "netkit (kernel $kern)" "≥ 6.8 and a netkit device was created" "Cilium $CILIUM_VERSION system requirements: netkit ≥ 6.8 + CONFIG_NETKIT (measured, not assumed)"
    else row no "netkit (kernel $kern)" "≥ 6.8 but no CONFIG_NETKIT exported and 'ip link add … type netkit' failed" "the kernel lacks CONFIG_NETKIT; the veth datapath stays (demo 06 Part 4)"; fi
  fi
else
  row no "netkit (kernel $kern)" "kernel < 6.8" "Cilium $CILIUM_VERSION system requirements: netkit ≥ 6.8 — on macOS this is Docker Desktop's kernel: upgrade Desktop (4.89.0: 7.0.12)"
fi
# Tetragon's base sensor (demo 17, blocker 1): the symbol must exist on the kernel the nodes share
# grep -c prints its 0 AND exits 1 on no match, so `|| echo 0` had made "0\\n0" — not an integer (review of 004, C7)
if [ "$os" = Linux ]; then sym=$(grep -c ' security_bprm_committing_creds$' /proc/kallsyms 2>/dev/null || true)
else sym=$(docker run --rm --privileged busybox:1.36 grep -c ' security_bprm_committing_creds$' /proc/kallsyms 2>/dev/null || true); fi
sym=${sym:-0}
if [ "$sym" -ge 1 ]; then row ok "Tetragon base sensor" "security_bprm_committing_creds exported" "demo 17 blocker 1 (CONFIG_SECURITY); blocker 2, /procHost, is in clusters/ci/*.yaml"
else row no "Tetragon base sensor" "security_bprm_committing_creds NOT in kallsyms" "demo 17 blocker 1 — LAB_TETRAGON=0, or another kernel"; fi
# two rows that are the same on every host, so nobody looks for them in the kernel
qd=$([ "$os" = Linux ] && sysctl -n net.core.default_qdisc 2>/dev/null || docker run --rm --privileged busybox:1.36 sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
row no "bandwidth manager + BBR" "off inside kind nodes (host default_qdisc=$qd)" "net.core.default_qdisc is host-netns only; a kind node is a container — any kernel (gotcha #103)"
row no "BIG TCP" "not with the lab's VXLAN tunnel" "needs native routing (the agent: 'BIG TCP in tunneling mode requires pending kernel support', gotcha #103)"

# ---------------------------------------------------------------- the node image for this CPU
plat=$(docker manifest inspect "$NODE_IMAGE" 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin); print(" ".join(sorted(e["platform"]["architecture"] for e in m.get("manifests", []) if e.get("platform", {}).get("os") == "linux")))' 2>/dev/null)
want=$([ "$arch" = arm64 ] || [ "$arch" = aarch64 ] && echo arm64 || echo amd64)
case " ${plat:-} " in
  *" $want "*) row ok "node image for $want" "${NODE_IMAGE%%@*} index: $plat" "the pinned digest is the OCI index, so it is the same line on amd64 and arm64" ;;
  *)           row REQUIRED-FAIL "node image for $want" "index platforms: ${plat:-unreadable}" "the pinned image has no $want manifest" ;;
esac

# ---------------------------------------------------------------- reaching the LB blocks from THIS host (SETUP Step 3.5)
case "$os" in
  Linux) row ok "route to the LB blocks" "the docker bridge is on this host: on-link" "scripts/lab-route.sh verifies Docker's connected route" ;;
  Darwin)
    vm_ip=$(docker run --rm --net=host --privileged busybox:1.36 sh -c "ip -4 addr show eth1 2>/dev/null | grep -o 'inet [0-9.]*'" 2>/dev/null | awk '{print $2}')
    if [ -n "$vm_ip" ]; then row ok "route to the LB blocks" "the VM has eth1 $vm_ip on a host bridge" "SETUP Step 3.5: 'sudo route -n add -net 172.18.0.0/16 $vm_ip' (scripts/lab-route.sh derives it)"
    else row warn "route to the LB blocks" "no eth1 in the VM" "SETUP Step 2.3b: 'Use kernel networking for UDP' off, or a VMM that gives the VM no host bridge — measured on the Apple Virtualization framework, not yet on Docker VMM"; fi ;;
esac

# ---------------------------------------------------------------- IPv6 on a docker network (the dual-stack runs)
n="lab-preflight-v6-$$"; trap 'docker network rm "$n" >/dev/null 2>&1 || true' EXIT   # this run's own name, gone on any exit (review, N4)
if docker network create --ipv6 --subnet fd00:1ab:9:9::/64 "$n" >/dev/null 2>&1 \
   && docker run --rm --net "$n" busybox:1.36 sh -c 'ip -6 addr show eth0 | grep -q "inet6 fd00:1ab:9:9"' >/dev/null 2>&1; then
  row ok "IPv6 on a docker network" "a container got fd00:1ab:9:9::/64" "LAB_IPFAMILY=dual is possible (cilium/values-ci-features.yaml)"
else row warn "IPv6 on a docker network" "no IPv6 address in a --ipv6 network" "dual-stack runs stay on the runner; Docker Desktop: check Resources → Network"; fi
docker network rm "$n" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- the kind network, if one already exists
if docker network inspect kind >/dev/null 2>&1; then
  sub=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
  case "$sub" in "${LAB_SUBNET:-172.18.0.0/16}"*) row ok "existing kind network" "$sub" "the lab's subnet (NETWORKING_DESIGN §4.2)" ;;
                 *) row warn "existing kind network" "$sub" "not the lab's ${LAB_SUBNET:-172.18.0.0/16}: lab-up.sh will stop — remove it when no cluster is on it (gotcha #95)" ;; esac
else row ok "kind network" "none yet" "lab-up.sh creates it with the lab's subnet and --ip-range (gotcha #95)"; fi
printf '\n'
[ "$STRICT" = 1 ] && [ "$failed" = 1 ] && { echo "::error::preflight: a REQUIRED row failed (see the table)"; exit 1; }
exit 0
