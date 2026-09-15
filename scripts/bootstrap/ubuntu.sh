#!/usr/bin/env bash
# bootstrap/ubuntu.sh — prepare an Ubuntu host for the lab, then hand over to the one path every host takes:
# scripts/lab-preflight.sh, then scripts/lab-up.sh. The bootstrap is the only per-host part of the lab (enhancement 004):
# GitHub's ubuntu-24.04 runner takes this — lab-observability.yaml, lab-spike-kind.yaml and lab-route-b.yaml call it in
# place of the install steps they used to carry inline (helm/kind-action, cilium/cilium-cli, a curl for hubble), so the
# runner's path IS this file and every run measures it — and a Mac takes scripts/bootstrap/macos.sh. Once Docker answers,
# nothing differs: the kind configs, the Cilium values and lab-up.sh are the same files on every host.
#
#   scripts/bootstrap/ubuntu.sh        # the tools at their pins (versions.env, sha256 checked), tcp_bbr, the preflight table
#
# The pins are installed from the projects' own releases with the checksum each publishes verified, into /usr/local/bin
# — the same binaries the two actions fetched. A tool already at its pin is kept; one at another version is replaced.
# Measured on the runner (run 34998586044, 2026-09-15): Ubuntu 24.04.5, kernel 6.17.0-azure, docker 28.0.4 and helm
# v3.21.4 preinstalled. An Ubuntu laptop takes the same steps; the two things a runner has and a laptop may not — docker
# and helm — are installed here when absent (helm from get.helm.sh at HELM_VERSION, checksum verified; docker from
# Ubuntu's archive, docker.io). The install path was measured in an ubuntu:24.04 container on arm64 (2026-09-15); the
# docker.io path on a real laptop has not been, and the runner never takes it.
set -euo pipefail; cd "$(dirname "$0")/../.." || exit 1
. scripts/bootstrap/versions.env
say() { printf '\n== %s\n' "$*"; }; die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || die "this is $(uname -s), not Linux — scripts/bootstrap/macos.sh is the Mac bootstrap"
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "no release binaries for $(uname -m)" ;; esac
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
BIN=/usr/local/bin
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# the pins here and lab-up.sh's own defaults must agree — one source, checked rather than trusted
grep -q "KIND_VERSION_WANT:-${KIND_VERSION#v}}" scripts/lab-up.sh && grep -q "CILIUM_VERSION:-$CILIUM_VERSION}" scripts/lab-up.sh \
  || die "scripts/bootstrap/versions.env and scripts/lab-up.sh disagree on a pin (KIND_VERSION_WANT / CILIUM_VERSION)"

say "the host: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") on $(uname -m) ($ARCH), kernel $(uname -r), $(nproc) CPUs, $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 )) GiB"
apt_install() { $SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "$@"; }
for t in curl tar; do command -v "$t" >/dev/null || { say "apt: $t"; apt_install curl ca-certificates tar; break; }; done
command -v python3 >/dev/null || { say "apt: python3 (the scripts' JSON handling)"; apt_install python3; }

fetch() { curl -sSL --fail --retry 5 --retry-all-errors --retry-delay 3 -o "$1" "$2"; }
verify() { # <file> <url of its published sha256> — both shapes the projects use: "<sha>  <name>" (kind, cilium, hubble, helm) or the bare hash (kubectl)
  local want have; want=$(curl -sSL --fail --retry 5 --retry-all-errors --retry-delay 3 "$2" | awk 'NR == 1 {print $1}')
  have=$(sha256sum "$1" | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$have" ] || die "sha256 mismatch for $(basename "$1"): published '${want:-none}', downloaded '$have' ($2)"
  echo "  sha256 ok: $(basename "$1") = ${have:0:16}…"
}
put() { $SUDO install -m 0755 "$1" "$BIN/$2"; echo "  installed $BIN/$2 ($("$BIN/$2" "${@:3}" 2>/dev/null | awk 'NR == 1'))"; }   # awk, not head: no SIGPIPE under pipefail

# ---------------------------------------------------------------- the pins, each compared before anything is downloaded
say "kind $KIND_VERSION (kubernetes-sigs/kind releases)"
if [ "$(kind version 2>/dev/null | awk '{print $2}')" = "$KIND_VERSION" ]; then echo "  at the pin: $(kind version)"; else
  fetch "$T/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH"
  verify "$T/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH.sha256sum"
  put "$T/kind" kind version; fi

say "kubectl $KUBECTL_VERSION (dl.k8s.io)"
have=$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || true)
if [ "$have" = "$KUBECTL_VERSION" ]; then echo "  at the pin: kubectl $have"; else
  fetch "$T/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  verify "$T/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl.sha256"
  put "$T/kubectl" kubectl version --client; fi

say "cilium-cli $CILIUM_CLI_VERSION (cilium/cilium-cli releases)"
if [ "$(cilium version --client 2>/dev/null | awk 'NR == 1 {print $2}')" = "$CILIUM_CLI_VERSION" ]; then echo "  at the pin: $(cilium version --client | head -1)"; else
  fetch "$T/cilium.tgz" "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-$ARCH.tar.gz"
  verify "$T/cilium.tgz" "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-$ARCH.tar.gz.sha256sum"
  tar -C "$T" -xzf "$T/cilium.tgz" cilium; put "$T/cilium" cilium version --client; fi

say "hubble $HUBBLE_CLI_VERSION (cilium/hubble releases) — the demo scripts' hubble observe"
# the release binary says "hubble v1.19.4@HEAD-39037bd …", a distribution's build "hubble 1.19.4 …": the pin is the bare number
hubble_have() { hubble version 2>/dev/null | awk '{print $2}' | sed -E 's/^v//; s/@.*//'; }
if [ "$(hubble_have)" = "$HUBBLE_CLI_VERSION" ]; then echo "  at the pin: $(hubble version)"; else
  fetch "$T/hubble.tgz" "https://github.com/cilium/hubble/releases/download/v$HUBBLE_CLI_VERSION/hubble-linux-$ARCH.tar.gz"
  verify "$T/hubble.tgz" "https://github.com/cilium/hubble/releases/download/v$HUBBLE_CLI_VERSION/hubble-linux-$ARCH.tar.gz.sha256sum"
  tar -C "$T" -xzf "$T/hubble.tgz" hubble; put "$T/hubble" hubble version; fi

# helm and docker: the runner has both preinstalled (helm's is the version the lab was measured with); a laptop may not
say "helm — $HELM_VERSION when absent (the runner's preinstalled version; the lab was measured with it)"
if command -v helm >/dev/null; then echo "  present: $(helm version --short) (kept; $HELM_VERSION is the measured one)"; else
  fetch "$T/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz"
  verify "$T/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz.sha256sum"
  tar -C "$T" -xzf "$T/helm.tgz" "linux-$ARCH/helm"; put "$T/linux-$ARCH/helm" helm version --short; fi

say "docker — Ubuntu's docker.io when absent (kind's provider)"
if command -v docker >/dev/null; then echo "  present: $(docker --version), engine $(docker version --format '{{.Server.Version}}' 2>/dev/null | awk 'NF {print; f = 1} END {if (!f) print "not answering"}') (kept)"; else
  apt_install docker.io
  if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then $SUDO systemctl enable --now docker; fi
  if [ -n "$SUDO" ] && ! id -nG | grep -qw docker; then $SUDO usermod -aG docker "$USER"; echo "  $USER added to the docker group — log in again before lab-up.sh (or run it with sudo -g docker)"; fi
  echo "  installed: $(docker --version)"; fi

# ---------------------------------------------------------------- the kernel: BBR (demo 06's congestion control) is a module on Ubuntu
# a kind node shares the host kernel and cannot load it, so the host must — the preflight and gotcha #103 say what stays off anyway
say "tcp_bbr"
$SUDO modprobe tcp_bbr 2>/dev/null || true
echo "  congestion=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo '?')"

# on a runner, the pins become the job's environment — lab-up.sh and lab-preflight.sh read CILIUM_VERSION, the steps read the rest
if [ -n "${GITHUB_ENV:-}" ]; then grep -E '^[A-Z_]+=' scripts/bootstrap/versions.env >> "$GITHUB_ENV"; echo "  pins exported to \$GITHUB_ENV"; fi

# ---------------------------------------------------------------- hand over to the one path: the preflight, the table every host prints
say "the toolchain"
printf '  kind %s | kubectl %s | helm %s | cilium-cli %s | hubble %s | docker %s | kernel %s\n' \
  "$(kind version | awk '{print $2}')" "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')" \
  "$(helm version --short)" "$(cilium version --client 2>/dev/null | awk 'NR == 1 {print $2}')" "$(hubble_have)" \
  "$(docker version --format '{{.Server.Version}}' 2>/dev/null | awk 'NF {print; f = 1} END {if (!f) print "daemon not answering"}')" "$(uname -r)"
CILIUM_VERSION="$CILIUM_VERSION" scripts/lab-preflight.sh
