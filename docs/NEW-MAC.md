# A new MacBook, from zero to the preflight

Written 2026-09-15 for the operator's Apple M5 Pro (64 GB). Everything here is the toolchain this lab was built and
verified with (`README.md` → *Versions*), the same scripts the CI job runs, and the Docker Desktop settings that
gotchas #103 and the runbook (`docs/DOCKER-DESKTOP-RUNBOOK.md`) were written for. Apple silicon changes two things
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
| Cursor CLI | `curl https://cursor.com/install -fsS \| bash` then `cursor agent login` | current | the second reviewer |

One line for the lab's tools:

```bash
brew install git gh kind kubernetes-cli helm cilium-cli hubble jq node go
brew install --cask docker-desktop codex
kind version; cilium version --client; hubble version; helm version --short; kubectl version --client
```

## 2. Podman, for the other projects

kind on Podman is experimental and needs a rootful machine (the research in `enhancements/004-lab-in-ci.md` §2: no
host route, poor ICMP through gvproxy), so this lab runs on Docker. Podman stays for the projects that use it (CRC,
the signal system's containers), and the two coexist — separate sockets, separate VMs:

```bash
brew install podman                                        # 6.1.1 on 2026-09-15 (Podman Desktop: brew install --cask podman-desktop)
podman machine init --cpus 4 --memory 8192 --disk-size 60  # its own VM; size it for the project that uses it
podman machine start
podman machine list                                         # one machine — the Intel Mac's lesson: stop the ones you are not using
```

`docker` stays `docker`: do not alias it to podman (kind's Docker provider reads Docker's socket and API).

## 3. Docker Desktop — the settings before any cluster (SETUP Step 2, gotcha #103)

Launch Docker Desktop once from `/Applications` (it asks for your password to install its helpers, then migrates
its settings file). Then quit it and set the VM from the file, because Docker Desktop reads the file at start and
overwrites it while running (SETUP Step 2.4's rule). On 4.35+ the file is `settings-store.json`; read it first, change
only what you read (the key names are what the file says, not what a guide remembers):

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
git clone https://github.com/ephico2real2/cilium-implementation-poc.git ~/gitRepos/cilium-kind-poc && cd ~/gitRepos/cilium-kind-poc
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

`/etc/hosts` for the browser: `demos/09-routes/hosts-entries.sh` prints the lines (grafana, hubble, cf2cnp, bank,
petclinic at the Gateway's address); the walker does not need them, a browser does.
