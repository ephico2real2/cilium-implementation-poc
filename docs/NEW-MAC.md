# A new MacBook, from zero to the preflight

Written 2026-09-15 for the operator's Apple M5 Pro (64 GB). Everything here is the toolchain this lab was built and
verified with (`README.md` → *Versions*), the same scripts the CI job runs, the Docker Desktop settings that
gotchas #103 and the runbook (`docs/DOCKER-DESKTOP-RUNBOOK.md`) were written for, and — because the same machine
carries the other projects — Podman, Podman Desktop and CRC with their measured minimums (§2). Apple silicon changes one thing
against the Intel MacBook: Homebrew lives under `/opt/homebrew`. The rest was measured on the M5 on 2026-09-15 and is in
§3 and §4: Docker Desktop 4.91.0's engine there is `linux/virtualization-framework` (its backend log), the host route to
the LB blocks works on it, and the per-host preparation is a script — `scripts/bootstrap/macos.sh` here,
`scripts/bootstrap/ubuntu.sh` on the runner — that ends in the same preflight table on both.

## 1. Homebrew, then the tools

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && eval "$(/opt/homebrew/bin/brew shellenv)"
brew --version
```

| Tool | Install | Version the lab pins or was verified with | Used by |
|---|---|---|---|
| git, gh | `brew install git gh` then `gh auth login` | any | the repo, the runs, the PRs (`gh run download`, `gh workflow run`) |
| Docker Desktop | `brew install --cask docker-desktop` | 4.91.0 on both Macs (kernel `7.0.12-linuxkit`, built **without** `CONFIG_NETKIT` — gotcha #109; the lab is veth on every Mac) | kind's provider: the clusters, `scripts/lab-images.sh` |
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

One line for the lab's tools — or let `scripts/bootstrap/macos.sh` (§3) install the lab's formulae and the Docker Desktop
cask; the reviewers, `go` and the docs' linter are yours:

```bash
brew install git gh kind kubernetes-cli helm cilium-cli hubble jq node go
brew install --cask docker-desktop codex
curl https://cursor.com/install -fsS | bash && echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # Cursor's CLI, `agent`; its installer puts it in ~/.local/bin
npm i -g markdownlint-cli2                                                                            # scripts/mdfmt and the .claude hook (missing on the M5 until 2026-09-15)
kind version; cilium version --client; hubble version; helm version --short; kubectl version --client; agent --version
```

What Homebrew gives against the pins the Action runs green with (`scripts/bootstrap/versions.env`), measured on the M5
on 2026-09-15: kind, cilium-cli and hubble at the pins; kubectl 1.37.0 against 1.36.4 (within the client skew); **helm
4.3.0 against 3.21.4** — brew's stable is Helm 4, the runner is on 3. Measured on the M5 the same day: `lab-up.sh poc1
poc2` completed under Helm 4.3.0 (Cilium, cert-manager, trust-manager, Hubble, Tetragon, the mesh apiserver — 9 min
34 s, enhancement 004 phase 4), so the mismatch is a difference to know, not a blocker; `brew install helm@3` is the
runner's major, keg-only. `macos.sh` prints this table every time.

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

## 3. Docker Desktop — the VM, from its settings file, by the bootstrap (SETUP Step 2, gotchas #103, #108)

Launch Docker Desktop once from `/Applications` (it asks for your password to install its helpers and writes its settings
file). Then, with the repository cloned (§4), one script does the rest of this section and hands over to the preflight:

```bash
scripts/bootstrap/macos.sh                                       # Homebrew's formulae, the VM's size and the UDP bridge, the preflight table
LAB_VM_CPUS=8 LAB_VM_MEMORY_MIB=16384 scripts/bootstrap/macos.sh # a smaller VM; LAB_VM_RESTART=0 reports and touches nothing
```

What it does, and why each step is the way it is — all of it measured on the M5 on 2026-09-15 (the script's header
carries the same facts):

- **The file and its spelling.** Docker Desktop reads its settings file at start and rewrites it while running (SETUP
  Step 2.4), so the script quits Desktop before writing and relaunches it after — and refuses while any container runs,
  because a quit stops them mid-flight. A Desktop installed fresh (4.91.0 on the M5) writes `settings-store.json` with
  its Go field names, `Cpus`, `MemoryMiB`, `KernelForUDP`; one upgraded in place from 4.27.2 (the Intel Mac) still
  writes the legacy `settings.json` in camelCase, `cpus`, `memoryMiB`, `kernelForUDP` (the runbook's diff). The store
  writes **only non-default keys**, so on a fresh install the three are absent — an earlier version of this section
  said "change only what you read" and then remembered the Intel spelling; gotcha #108 is that lesson. The script picks
  the spelling by the file that exists.
- **The allocation:** 10 CPUs and 24 GB on 64 GB — the CI lab used 12.5 GB with every stack and the petclinic up, the
  Intel Mac ran the seven-node lab on 16 GB. Desktop's default is every core and 8 GB, and 8 GB fails the preflight
  (`memory for the nodes 7 GiB REQUIRED-FAIL` — the M5's first table).
- **`KernelForUDP`** is what puts the VM on a bridge the host can route to (Step 2.3b / 3.5: `open https://grafana.poc.local`
  from this Mac). Measured on the M5: the VM got `eth1 192.168.64.2` **on a user-mode install with no vmnetd** (the
  backend log: "vmnetd is not installed on this system", `RequireVmnetd: false`), so the privileged helper is not what
  the route needs. Desktop's caveat on the switch: "may not be compatible with your VPN software".
- **The proof is read from the VM, not the file:** `docker info` must answer the CPUs asked for and a MemTotal within
  1.5 GiB of the setting (the kernel keeps some), and the keys must survive Desktop's own rewrite. The M5:

```text
written; the proof — only these lines differ from …/settings-store.json.before-2026-09-15T162750:
>   "Cpus": 10,
>   "MemoryMiB": 24576,
>   "KernelForUDP": true
the VM answers: CPUs=10 MemTotal=23994 MiB Kernel=7.0.12-linuxkit
settings-store.json after the relaunch: Cpus=10 MemoryMiB=24576 KernelForUDP=true
engine: linux/virtualization-framework
  ok            memory for the nodes       23 GiB
  ok            route to the LB blocks     the VM has eth1 192.168.64.2 on a host bridge
```

The virtual machine type is under Settings → General; the M5's 4.91.0 runs `linux/virtualization-framework` (the
backend log's "starting engine" line, which the script prints), the VMM the host route was measured on. Docker VMM
remains unmeasured for the route. The kernel is `7.0.12-linuxkit` on both Macs and it is built without `CONFIG_NETKIT`
(gotcha #109): the lab is veth here, as it is on every gated run.

## 4. The repository, the preflight, the lab

```bash
git clone https://github.com/ephico2real2/cilium-implementation-poc.git ~/gitRepos/cilium-implementation-poc && cd ~/gitRepos/cilium-implementation-poc
scripts/bootstrap/macos.sh        # §3; ends in the preflight table: netkit on this kernel, Tetragon's symbol, the route to the LB blocks, IPv6, the node image's platform
scripts/lab-preflight.sh          # the table alone, any time — lab-up.sh runs it again, strictly
```

Read the table before the bring-up. The two rows Apple silicon had never measured were measured on the M5 on
2026-09-15 (enhancement 004, phase 4): **netkit `no`** — the kernel has no `CONFIG_NETKIT` (gotcha #109), which changes
nothing for the lab; **route `ok`** — `eth1 192.168.64.2` on a host bridge once `KernelForUDP` is on (§3). Then the same
path as the CI job, in order:

```bash
LAB_TRUST_ROOT=1 scripts/lab-up.sh poc1 poc2     # the clusters, the mesh; the root into this Mac's keychain (a password prompt) and into every namespace (demo 36)
                                                 # from a shell that cannot prompt (an agent's): scripts/lab-up.sh poc1 poc2, then scripts/lab-trust.sh install kind-poc1 yourself — the M5's first bring-up, 2026-09-15, 9 min 34 s
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
