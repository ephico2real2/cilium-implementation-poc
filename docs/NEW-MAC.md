# A new MacBook, from zero to the preflight

Written 2026-09-15 for the operator's Apple M5 Pro (64 GB). Everything here is the toolchain this lab was built and
verified with (`README.md` → *Versions*), the same scripts the CI job runs, the Docker Desktop settings that
gotchas #103 and the runbook (`docs/DOCKER-DESKTOP-RUNBOOK.md`) were written for, and — because the same machine
carries the other projects — Podman, Podman Desktop and CRC with their measured minimums (§2). Apple silicon changes two things
against the Intel MacBook: Homebrew lives under `/opt/homebrew`, and Docker Desktop's default virtual machine is
Docker VMM, on which the host route to the LB blocks (Step 3.5) is unmeasured — the preflight tells.

## 1. Homebrew, then the tools

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && eval "$(/opt/homebrew/bin/brew shellenv)"
brew --version
```

| Tool | Install | Version the lab pins or was verified with | Used by |
|---|---|---|---|
| git, gh | `brew install git gh` then `gh auth login` | any | the repo, the runs, the PRs (`gh run download`, `gh workflow run`) |
| Docker Desktop | `brew install --cask docker-desktop` | ≥ 4.89.0 (kernel 7.0.12 — netkit needs ≥ 6.8); 4.91.0 on the Intel Mac | kind's provider: the clusters, `scripts/lab-images.sh` |
| kind | `brew install kind` | **0.33.0** (the node image is pinned by digest, `kindest/node:v1.36.4@sha256:099e…`, an index with `linux/arm64`) | `scripts/lab-up.sh` |
| kubectl | `brew install kubernetes-cli` | 1.31+ (the clusters are 1.36.4; within skew) | everything |
| helm | `brew install helm` | 3.14+ | Cilium, cert-manager, trust-manager, Kyverno, the stacks |
| cilium-cli | `brew install cilium-cli` | **0.20.0** | `cilium status --wait`, `clustermesh status`, the connectivity test |
| hubble | `brew install hubble` | **1.19.4** | every demo's `hubble observe`; `scripts/hubble-tls.sh` |
| jq | `brew install jq` | any | the scripts (`lab-apps.sh`, `lab-policies.sh`, the workflow's proof loops) |
| python3 | macOS's is enough; `brew install python` for 3.13 | 3.9+ | the scripts' JSON and URL handling |
| node | `brew install node` | 20+ | Playwright (`scripts/lab-capture.sh` installs it into `.tmp/pw`), the walker |
| go | `brew install go` | 1.22+ | optional: `demos/25-hubble-observer-loki/logql-test` (the dashboard's queries through Loki's engine) |
| openssl | macOS's LibreSSL is enough | any | the certificate lines the checks print |
| Codex CLI | `brew install --cask codex` then `codex login` | 0.154.0 on 2026-09-15 | the adversarial review (see `docs/REVIEW_*.md`) |
| Cursor CLI | `curl https://cursor.com/install -fsS \| bash`, then `agent login` — the binary is **`agent`** in `~/.local/bin` (Cursor's installation page: verify with `agent --version`, update with `agent update`); `cursor agent …` only works where the Cursor IDE's `cursor` launcher is installed | 2026.09.10 on the Intel Mac | the second reviewer: `agent -p --mode ask --output-format text --trust --model cursor-grok-4.6-high-fast "<brief>"` |
| Podman | `brew install podman` — one install path only, §2 | 6.1.1 (brew stable, 2026-09-15); 5.5.2 on the Intel Mac | the other projects: `release-crc.sh` builds and pushes the dashboard's images with it |
| Podman Desktop | `brew install --cask podman-desktop` | 1.29.3 cask (2026-09-15); 1.26.2 on the Intel Mac | the GUI for the Podman machine and, with its OpenShift Local extension, for CRC |
| CRC (OpenShift Local) | not in Homebrew — the guided installer from console.redhat.com/openshift/create/local, a Red Hat account, the pull secret from the same page | v2.63.0 (2026-08-18); 2.49.0 / OpenShift 4.18.2 on the Intel Mac | the dashboard project's cluster — §2 has its minimums |
| oc | `crc oc-env` (the cluster's own) or `brew install openshift-cli` | 4.22.12 (brew); 4.13.6 on the Intel Mac | CRC |

One line for the lab's tools:

```bash
brew install git gh kind kubernetes-cli helm cilium-cli hubble jq node go
brew install --cask docker-desktop codex
curl https://cursor.com/install -fsS | bash && echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # Cursor's CLI, `agent`; its installer puts it in ~/.local/bin
kind version; cilium version --client; hubble version; helm version --short; kubectl version --client; agent --version
```

## 2. Podman, Podman Desktop and CRC — for the other projects

This lab runs on Docker. kind auto-detects its provider and takes Docker whenever `docker -v` answers
`Docker version …` (kind v0.33.0, `pkg/cluster/provider.go` `DetectNodeProvider`, then `docker/util.go` `IsAvailable`);
Podman comes after, behind `KIND_EXPERIMENTAL_PROVIDER` in kind's quick start, which adds that rootless podman needs
"extra setup … for KIND clusters to be fully functional"; and its machine has no host route to a container IP —
user-mode networking through gvproxy, whose maintainer says it "does not seem to handle ICMP well" (containers/podman
discussion #24235; gvisor-tap-vsock's README limitations). Step 3.5's route from this Mac to the LB blocks needs Docker
Desktop's bridge. SETUP Step 0.3 made the same call for the reason it could measure then (a 2 GiB Podman machine).

Podman is for the other projects. CRC itself needs none of it — its VM is vfkit's and its presets are `openshift`, `okd`
and `microshift` (`crc config set --help` on 2.49.0; the `podman` preset is gone) — but the dashboard's release path is
Podman end to end: `local-development/release-crc.sh` in group-sync-dashboard is `podman build`, `podman run`,
`podman login`, `podman tag`, `podman push` into CRC's internal registry.

**One install path for Podman, never two.** Podman Desktop's macOS page recommends its own `.dmg` (it bundles the engine
and the CLI under `/opt/podman`) and says of Homebrew: not recommended — and, if Podman is already Homebrew's, "Do not use
the .dmg installer to install Podman Desktop. Instead, use Homebrew only." The Intel Mac is the state that page warns about: Homebrew's `podman` 5.5.2 first
on `PATH`, the pkg's `/opt/podman/bin/podman` behind it, and a Podman Desktop that auto-updated from the 1.17.2 cask to
1.26.2. The M5 takes Homebrew only, because everything else here is Homebrew and one `brew upgrade` moves them together:

```bash
brew install podman                                        # gvproxy and vfkit come with the formula
brew install --cask podman-desktop                         # finds Homebrew's podman; in its onboarding, skip "install Podman" — it is installed
podman machine init --cpus 4 --memory 4096 --disk-size 60  # its own VM (applehv); the Intel Mac's 8 CPUs / 2 GiB / 100 GiB builds the dashboard image
podman machine start && podman machine list
```

**CRC — what it needs**, from crc.dev (*Installing*, *Configuring*, *Administrative tasks*) and `crc config set --help`:

| | The floor | The Intel Mac, measured 2026-09-15 (`crc config view`, `oc describe node`, `df` inside) | The M5 — a proposal from those measurements |
|---|---|---|---|
| macOS | 15 Sequoia or later | 15.7.9 | what the M5 ships with |
| preset | `openshift` — 4 physical cores, 10.5 GB free memory, 35 GB of storage; `okd` is not on Apple silicon | openshift, 4.18.2 | openshift |
| `cpus` | ≥ 4 | 5 → 4800m allocatable, **4792m requested (99 %)**: 2322m the platform, 2410m the operator's workloads | 8 (6 if `sysctl -n hw.ncpu` says fewer than 14) |
| `memory` | ≥ 10752 MiB; **14336** "recommended for core functionality" once `enable-cluster-monitoring` is true | 16384 → 15540Mi allocatable (the kubelet keeps 843Mi), **13165Mi requested (85 %)** with monitoring off: 9457Mi the platform, 3708Mi the operator's | 20480 → ~19637Mi allocatable; today's 13165Mi + monitoring's ~3584Mi (the docs' 14336 less the 10752 default) = 16749Mi, ~2.8 GiB left to schedule. At 16384 that sum exceeds the 15540Mi allocatable: Pending pods the moment monitoring is on |
| `disk-size` | ≥ 31 GiB | 60 → **50G used, 9.5G free (85 %)** in 17 months (the instance dates from 2025-04-18); `crc.img` fully allocated, 60 GB on disk | 100 — grow-only: a larger value is applied at the next `crc start` (crc v2.63.0 `pkg/crc/machine/start.go` → `setDiskSize` → the vfkit driver's `resize`: `os.Truncate`, then `growpart`), a smaller one is refused |
| monitoring | off by default ("so that CRC can run on a typical notebook"); once on it cannot be turned off without `crc delete` | off (no Metrics API: `oc adm top` fails) | on — the dashboard's parked monitoring validation needs it; decide before the first start |

```bash
crc setup                                                                    # a password prompt: the helper and the network
crc config set cpus 8; crc config set memory 20480; crc config set disk-size 100
crc config set enable-cluster-monitoring true                                # the 14336 MiB floor above; cannot be undone without crc delete
crc config set pull-secret-file ~/.crc/pull-secret.json                      # no prompt on any later start
crc start                                                                    # "a minimum of four minutes"; then crc console --credentials
eval "$(crc oc-env)"; oc get co                                              # the cluster's own oc
```

**The memory budget on 64 GB**, if the lab and CRC run at once: Docker Desktop 24 GB (§3, a cap; the lab's footprint
measured 12.5 GB in CI) + CRC 20 GB + the Podman machine 4 GB = 48 GB in virtual machines, 16 GB for macOS, the
browser and the two reviewers; 22 vCPUs over the host's threads, fine as threads, noisier for demo 06's throughput
numbers while CRC is up. That sum is why the Intel Mac's 32 GB never ran the two together and why Docker Desktop stays
quit there when CRC is up. `cpus`, `memory` and a larger `disk-size` change with `crc config set` then `crc stop` /
`crc start`; only monitoring and a smaller disk need a fresh instance.

**The socket, measured on the Intel Mac.** Podman Desktop's *Docker compatibility* installs `podman-mac-helper`, which points
`/var/run/docker.sock` at the Podman machine; Docker Desktop's *Allow the default Docker socket to be used*
(`enableDefaultDockerSocket`) names the same path and is on there. Today `/var/run/docker.sock →
…/podman/machine/podman.sock` (2026-09-13 18:08, and still so after Docker Desktop's last run on the 14th), and the two
coexist because the `docker` CLI is on its `desktop-linux` context (`~/.docker/run/docker.sock`) — that context is what
kind talks to. The rules: `docker context show` prints `desktop-linux`;
`DOCKER_HOST` is never exported (with it set, `docker context ls` moves the star to `default` at that endpoint — measured);
`docker` is never aliased to podman, because then `docker -v` says `podman version` and kind stops seeing Docker.

## 3. Docker Desktop — the settings before any cluster (SETUP Step 2, gotcha #103)

Launch Docker Desktop once from `/Applications` (it asks for your password to install its helpers, then migrates
its settings file). Then quit it and set the VM from the file, because Docker Desktop reads the file at start and
overwrites it while running (SETUP Step 2.4's rule). Docker's documentation names the file `settings-store.json`; the
Intel Mac's 4.91.0, upgraded in place from 4.27.2, still writes `settings.json` (its mtime moves on every change) and has
no `settings-store.json` — so read whichever exists, and change only what you read (the key names are what the file
says, not what a guide remembers):

```bash
f="$HOME/Library/Group Containers/group.com.docker/settings-store.json"; [ -f "$f" ] || f="$HOME/Library/Group Containers/group.com.docker/settings.json"
python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sorted(d):
    if any(s in k.lower() for s in ("cpu", "memory", "kernelforudp", "vmtype", "virtualization", "swap", "disk", "autostart")): print(f"  {k:40} {d[k]!r}")
PY
```

The allocation for this machine — 64 GB is enough to run the full lab beside Podman: 10 CPUs and 24 GB (the CI
lab used 12.5 GB with every stack and the petclinic up; the Intel Mac ran the seven-node lab on 16 GB):

```bash
b="$f.before-$(date +%Y-%m-%d)"; cp -p "$f" "$b"
python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
before = {k: d.get(k) for k in ("cpus", "memoryMiB", "kernelForUDP")}
d["cpus"] = 10; d["memoryMiB"] = 24576; d["kernelForUDP"] = True
json.dump(d, open(p, "w"), indent=2); print(before, "->", {k: d[k] for k in before})
PY
diff <(python3 -m json.tool "$b") <(python3 -m json.tool "$f")      # the proof: only those lines changed
```

`kernelForUDP` is what puts the VM on a bridge the host can route to (Step 2.3b / 3.5: `open https://grafana.poc.local`
from this Mac). The virtual machine type (Docker VMM or the Apple Virtualization framework) is under Settings →
General; the host route was measured only on the Virtualization framework. Launch Docker Desktop again, then:

```bash
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}} Kernel={{.KernelVersion}} Arch={{.Architecture}}'
```

## 4. The repository, the preflight, the lab

```bash
git clone https://github.com/ephico2real2/cilium-implementation-poc.git ~/gitRepos/cilium-implementation-poc && cd ~/gitRepos/cilium-implementation-poc
scripts/lab-preflight.sh          # the table: netkit on this kernel, Tetragon's symbol, the route to the LB blocks, IPv6, the node image's platform
```

Send the table before the bring-up: its netkit and route rows are the two things Apple silicon has not measured
yet (enhancement 004, phase 4). Then the same path as the CI job, in order:

```bash
LAB_TRUST_ROOT=1 scripts/lab-up.sh poc1 poc2     # the clusters, the mesh; the root into this Mac's keychain (a password prompt) and into every namespace (demo 36)
scripts/lab-images.sh poc1 poc2                  # the lab's images, built here (arm64) and loaded into both clusters
scripts/lab-stack.sh all                         # demos 09, 16, 21, 10/22/23, 25, 18, the CLI's certificate, Kyverno
scripts/lab-apps.sh all                          # the labs of 26–35, the bank, the forensic client, the petclinic, the labelled client
scripts/lab-apps.sh rounds 3                     # the observation the policies are generated from
scripts/lab-policies.sh all                      # the cf2cnp chapters: flows → policies, validated three ways, applied, re-tested
scripts/lab-apps.sh traffic 6                    # enforced traffic, then the wait for Prometheus, Loki and Tempo from both clusters
scripts/lab-report.sh captures/report.md         # the demos' own checks
scripts/lab-capture.sh                           # the pages, with their expectations (Playwright into .tmp/pw on first use)
scripts/lab-down.sh                              # when done; scripts/cluster-pause.sh keeps them for tomorrow
```

`/etc/hosts` for the browser: each stack's demo prints its lines — `demos/16-monitoring/hosts-entries.sh` (grafana),
`demos/25-hubble-observer-loki/hosts-entries.sh` (cf2cnp), `demos/15-bank/hosts-entries.sh`,
`demos/20-springboot/hosts-entries.sh` — `sudo sh -c 'demos/16-monitoring/hosts-entries.sh >> /etc/hosts'` as SETUP
Step 9.5b does; the walker does not need them, a browser does.
