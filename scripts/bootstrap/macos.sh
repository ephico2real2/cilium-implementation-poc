#!/usr/bin/env bash
# bootstrap/macos.sh — prepare THIS MacBook (Intel or Apple silicon) for the lab, then hand over to the one path every host
# takes: scripts/lab-preflight.sh, then scripts/lab-up.sh. The bootstrap is the only per-host part of the lab (enhancement
# 004): a GitHub runner or an Ubuntu laptop takes scripts/bootstrap/ubuntu.sh, a Mac takes this. Once Docker answers with
# a VM the lab fits in, nothing differs — the kind configs, the Cilium values and lab-up.sh are the same files on every host.
# docs/NEW-MAC.md §1 and §3 are this script's prose.
#
#   scripts/bootstrap/macos.sh                                        # tools via Homebrew, Docker Desktop's VM from its file, the preflight
#   LAB_VM_CPUS=8 LAB_VM_MEMORY_MIB=16384 scripts/bootstrap/macos.sh  # a smaller VM (the Intel Mac ran the seven-node lab on 16 GB)
#   LAB_VM_RESTART=0 scripts/bootstrap/macos.sh                       # say what the VM would need and touch nothing
#
# What is measured, not chosen:
#   - the VM's size: 10 CPUs / 24 GB on a 64 GB machine — the CI lab used 12.5 GB with every stack and the petclinic up, the
#     Intel Mac ran the full-size clusters on 16 GB (SETUP Step 2.3); Docker Desktop's default, 8 GB, fails the preflight
#     (the M5 Pro, 2026-09-15: "memory for the nodes 7 GiB REQUIRED-FAIL").
#   - the settings file and its key names. A Docker Desktop installed fresh (4.91.0 on the M5) writes settings-store.json
#     with its Go field names — Cpus, MemoryMiB, KernelForUDP — the store's struct as read from the 4.91.0 backend binary;
#     a Desktop upgraded in place from 4.27.2 (the Intel Mac) still writes the legacy settings.json in camelCase — cpus,
#     memoryMiB, kernelForUDP (docs/DOCKER-DESKTOP-RUNBOOK.md, the measured diff). Desktop reads the file at start and
#     rewrites it while running (SETUP Step 2.4), so it is quit before the write and relaunched after — and only when
#     nothing is running in it: a quit stops every container mid-flight.
#   - kernelForUDP is what gives the VM eth1 on a bridge the host can route to — the next hop of the route to the LB blocks
#     (SETUP Step 3.5, scripts/lab-route.sh), measured on the Apple Virtualization framework. Desktop's own caveat on the
#     switch: "may not be compatible with your VPN software".
# What stays the operator's, on purpose: Homebrew's installer and Docker Desktop's first launch (both ask for a password),
# the logins (gh, codex, agent), Podman and CRC (NEW-MAC §2, other projects), and Docker Desktop's privileged helper
# (vmnetd — a system-mode install; this Desktop was installed in user mode, "vmnetd is not installed on this system").
set -euo pipefail; cd "$(dirname "$0")/../.." || exit 1
. scripts/bootstrap/versions.env
LAB_VM_CPUS="${LAB_VM_CPUS:-10}"; LAB_VM_MEMORY_MIB="${LAB_VM_MEMORY_MIB:-24576}"; LAB_VM_RESTART="${LAB_VM_RESTART:-1}"
say() { printf '\n== %s\n' "$*"; }; die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "this is $(uname -s), not macOS — scripts/bootstrap/ubuntu.sh is the Linux bootstrap"
# the pins here and lab-up.sh's own defaults must agree — one source, checked rather than trusted
grep -q "KIND_VERSION_WANT:-${KIND_VERSION#v}}" scripts/lab-up.sh && grep -q "CILIUM_VERSION:-$CILIUM_VERSION}" scripts/lab-up.sh \
  || die "scripts/bootstrap/versions.env and scripts/lab-up.sh disagree on a pin (KIND_VERSION_WANT / CILIUM_VERSION)"

# ---------------------------------------------------------------- Homebrew and the tools (NEW-MAC §1)
say "the host: macOS $(sw_vers -productVersion) on $(uname -m), $(sysctl -n hw.ncpu) CPUs, $(( $(sysctl -n hw.memsize) / 1073741824 )) GiB"
command -v brew >/dev/null || die 'Homebrew is not installed; its installer asks for your password, so it is yours to run: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" — then run this again (NEW-MAC §1)'
FORMULAE="kind kubernetes-cli helm cilium-cli hubble jq node"     # NEW-MAC §1's line; go is optional (demo 25's logql-test) and left out
missing=""; for f in $FORMULAE; do brew list --formula --versions "$f" >/dev/null 2>&1 || missing="$missing $f"; done
if [ -n "$missing" ]; then say "brew install$missing"; brew install $missing; else say "Homebrew: every formula present ($FORMULAE)"; fi
[ -d /Applications/Docker.app ] || { say "brew install --cask docker-desktop"; brew install --cask docker-desktop; }

# the versions Homebrew gave against the pins the Action runs green with — brew cannot pin, so this is a report: kind must
# match (the node image is pinned for it; lab-up.sh warns), kubectl within one minor is inside the client skew, and helm
# is the line to read first if lab-up.sh ever misbehaves here (brew's stable is 4.x; the lab was measured on 3.21.4 only)
say "the tools, against scripts/bootstrap/versions.env"
v_kind=$(kind version | awk '{print $2}')
v_kubectl=$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')
# awk reads every line: a grep -m1 here closes the pipe on the first match, cilium dies of SIGPIPE (141) and pipefail ends the script
v_helm=$(helm version --template '{{.Version}}'); v_cilium=$(cilium version --client 2>/dev/null | awk 'NR == 1 {print $2}'); v_hubble=$(hubble version | awk '{print $2}')
row() { printf '  %-12s %-12s %-12s %s\n' "$1" "$2" "$3" "$4"; }
cmp() { if [ "$2" = "$3" ]; then row "$1" "$2" "$3" "="; else row "$1" "$2" "$3" "≠ — $4"; fi; }
row TOOL HERE PIN NOTE
cmp kind "$v_kind" "$KIND_VERSION" "the node image is pinned for $KIND_VERSION; lab-up.sh warns (brew has no kind@$KIND_VERSION: kubernetes-sigs/kind releases)"
cmp kubectl "$v_kubectl" "$KUBECTL_VERSION" "the clusters are $KUBECTL_VERSION; one minor either way is within the client skew"
cmp helm "$v_helm" "$HELM_VERSION" "the lab was measured with $HELM_VERSION (the runner's); brew install helm@3 is the same major, keg-only"
cmp cilium-cli "$v_cilium" "$CILIUM_CLI_VERSION" "0.19.7 did not know 1.20's CiliumCIDRGroup v2"
cmp hubble "$v_hubble" "$HUBBLE_CLI_VERSION" "the demos' hubble observe"

# ---------------------------------------------------------------- Docker Desktop's VM, from its settings file (NEW-MAC §3, SETUP Step 2)
app=$(defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "?")
say "Docker Desktop $app: the VM's size and the UDP bridge, from the file"
G="$HOME/Library/Group Containers/group.com.docker"
if [ -f "$G/settings-store.json" ]; then sf="$G/settings-store.json"; K_CPUS=Cpus; K_MEM=MemoryMiB; K_UDP=KernelForUDP    # installed fresh: the store's field names
elif [ -f "$G/settings.json" ]; then sf="$G/settings.json"; K_CPUS=cpus; K_MEM=memoryMiB; K_UDP=kernelForUDP          # upgraded in place: the legacy file
else die "Docker Desktop has never been started here: open -a Docker once (it asks for your password for its helpers and writes $G/settings-store.json), then run this again"; fi
# Desktop writes only non-default keys, so an absent key IS the default (8 GB, every core, UDP off) — read as null here
read -r have_cpus have_mem have_udp < <(python3 - "$sf" "$K_CPUS" "$K_MEM" "$K_UDP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); print(*(json.dumps(d.get(k)) for k in sys.argv[2:]))
PY
)
echo "$(basename "$sf"): $K_CPUS=$have_cpus $K_MEM=$have_mem $K_UDP=$have_udp   (null = Desktop's default, the key not written)"
echo "wanted:              $K_CPUS=$LAB_VM_CPUS $K_MEM=$LAB_VM_MEMORY_MIB $K_UDP=true"
if [ "$have_cpus" = "$LAB_VM_CPUS" ] && [ "$have_mem" = "$LAB_VM_MEMORY_MIB" ] && [ "$have_udp" = true ]; then
  echo "the file already says so; nothing to write"
elif [ "$LAB_VM_RESTART" != 1 ]; then
  echo "LAB_VM_RESTART=0: not written. To apply: quit Docker Desktop, set the three keys above in $sf, relaunch it"
else
  # a quit stops every container in the VM — refuse while anything runs, rather than take a running cluster down
  if docker info >/dev/null 2>&1; then
    n=$(docker ps -q | wc -l | tr -d ' ')
    [ "$n" = 0 ] || die "$n container(s) are running in the VM ($(docker ps --format '{{.Names}}' | tr '\n' ' '))— stop them (scripts/cluster-pause.sh, scripts/lab-down.sh) before the VM is resized"
  fi
  if pgrep -xq 'Docker Desktop' || pgrep -xq com.docker.backend; then
    echo "quitting Docker Desktop (the file is rewritten while it runs — SETUP Step 2.4)"
    osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 || osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
    for _ in $(seq 1 90); do pgrep -xq 'Docker Desktop' || pgrep -xq com.docker.backend || break; sleep 1; done
    pgrep -xq com.docker.backend && die "Docker Desktop did not quit in 90 s — quit it from the menu bar and run this again"
  fi
  b="$sf.before-$(date +%Y-%m-%dT%H%M%S)"; cp -p "$sf" "$b"
  python3 - "$sf" "$K_CPUS" "$LAB_VM_CPUS" "$K_MEM" "$LAB_VM_MEMORY_MIB" "$K_UDP" <<'PY'
import json, sys
p, kc, c, km, m, ku = sys.argv[1:]
d = json.load(open(p))
d[kc] = int(c); d[km] = int(m); d[ku] = True
with open(p, "w") as f:                       # the file's own shape: two-space indent, one key per line
    json.dump(d, f, indent=2); f.write("\n")
PY
  echo "written; the proof — only these lines differ from $b:"
  diff "$b" "$sf" || true
  echo "relaunching Docker Desktop"
  open -a Docker
  for _ in $(seq 1 240); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 || die "the daemon did not answer within 240 s of the relaunch"
  # read back from the VM, not from the file: the kernel keeps some of the memory, so MemTotal is a little under the setting
  ncpu=$(docker info --format '{{.NCPU}}'); mem_mib=$(( $(docker info --format '{{.MemTotal}}') / 1048576 ))
  echo "the VM answers: CPUs=$ncpu MemTotal=${mem_mib} MiB Kernel=$(docker info --format '{{.KernelVersion}}')"
  [ "$ncpu" = "$LAB_VM_CPUS" ] || die "the VM has $ncpu CPUs, not $LAB_VM_CPUS — Desktop did not take $K_CPUS from $(basename "$sf")"
  [ "$mem_mib" -ge $(( LAB_VM_MEMORY_MIB - 1536 )) ] && [ "$mem_mib" -le "$LAB_VM_MEMORY_MIB" ] \
    || die "the VM has $mem_mib MiB, not about $LAB_VM_MEMORY_MIB — Desktop did not take $K_MEM from $(basename "$sf")"
  # and the file after Desktop rewrote it: the keys survive only if they are the store's own names
  read -r c2 m2 u2 < <(python3 - "$sf" "$K_CPUS" "$K_MEM" "$K_UDP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); print(*(json.dumps(d.get(k)) for k in sys.argv[2:]))
PY
)
  echo "$(basename "$sf") after the relaunch: $K_CPUS=$c2 $K_MEM=$m2 $K_UDP=$u2"
  [ "$u2" = true ] || echo "::warning::$K_UDP did not survive Desktop's rewrite — the preflight's route row says whether eth1 exists anyway"
fi
# which virtual machine the engine runs on — the host route to the LB blocks was measured on the Virtualization framework only
L="$HOME/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.log"
[ -r "$L" ] && echo "engine: $(grep -oE 'starting engine linux/[a-z0-9-]+' "$L" | tail -1 | sed 's/starting engine //')  (com.docker.backend.log; the route was measured on linux/virtualization-framework)"

# ---------------------------------------------------------------- hand over to the one path: the preflight, the table every host prints
scripts/lab-preflight.sh
echo "next: LAB_TRUST_ROOT=1 scripts/lab-up.sh poc1 poc2   (NEW-MAC §4) — after reading the table above"
