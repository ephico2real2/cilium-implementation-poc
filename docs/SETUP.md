# SETUP — build the Cilium + Hubble PoC from nothing

A step-by-step guide written for someone who has not done this before. **Every command is given on
its own**, with what it does, what output to expect, and how to tell it worked. Nothing is chained
or abbreviated. Real output captured on the build machine is shown under each command — yours will
differ in versions, IPs and hashes, but the *shape* should match.

- Host used for this guide: macOS (Darwin 24.6.0), x86_64, 16 CPU, 32 GB RAM
- Date of capture: 2026-09-10

**How to read this.** Each step is `### Step N — title`, then **Why**, then **Run**, then **Expected
output**, then **Check**. If a Check fails, stop and read the Troubleshooting note for that step
rather than continuing — later steps assume earlier ones succeeded.

---

## Step 0 — know what you already have

### Step 0.1 — inventory the toolchain

**Why.** Four tools matter: `kind` (creates the cluster), `kubectl` (talks to it), `helm` (installs
Cilium) and a container runtime (`docker` or `podman`) that kind runs the nodes inside. Two more —
the `cilium` and `hubble` CLIs — we install later. Knowing what is present, and at what version,
before changing anything means you can undo it.

**Run** — one line per tool, so a missing tool cannot hide behind another's output:

```bash
kind --version
kubectl version --client
helm version --short
docker --version
podman --version
```

**Expected output** (what this machine reported):

```
kind version 0.25.0
Client Version: v1.31.3
v3.14.0+g3fc9f4b
Docker version 25.0.3, build 4debf41
podman version 5.5.2
```

`cilium version --client` and `hubble version` both reported *command not found* — expected, we
install them in Step 2.

**Check.** You have some version of kind, kubectl, helm and at least one of docker/podman. Exact
versions do not matter yet; we upgrade in Step 1.

### Step 0.2 — is the container runtime actually running?

**Why.** Having the `docker` *client* installed is not the same as having the *daemon* running. kind
shells out to the daemon for everything, and its error when the daemon is down is long and
alarming-looking but means only "start Docker".

**Run:**

```bash
docker info --format '{{.ServerVersion}} / CPUs={{.NCPU}} / Mem={{.MemTotal}}'
```

**Expected output when the daemon is DOWN** (this machine, before starting it):

```
 /  / CPUs=0 / Mem=0
```

Empty values are the tell. Running `kind get clusters` in this state gives:

```
ERROR: failed to list clusters: command "docker ps -a ..." failed with error: exit status 1
Cannot connect to the Docker daemon at unix:///Users/olasumbo/.docker/run/docker.sock.
Is the docker daemon running?
```

**Check.** If you saw empty values, that is fine — Step 1.3 starts it.

### Step 0.3 — decide the container runtime

**Why.** kind supports Docker and (experimentally) Podman. They are not equivalent for this PoC:
Cilium loads eBPF programs and needs a Linux kernel with the right mounts, and the Docker path is
what Cilium's own CI exercises. Podman also works but is the less-travelled road.

**Run** — check what each provider actually has available:

```bash
docker context ls
```

```bash
podman machine list
```

**Expected output** (this machine):

```
NAME              TYPE   DESCRIPTION                DOCKER ENDPOINT
default           moby   Current DOCKER_HOST ...    unix:///var/run/docker.sock
desktop-linux *   moby   Docker Desktop             unix:///Users/olasumbo/.docker/run/docker.sock
podman            moby   Podman                     unix:///.../podman-machine-default-api.sock
```

```
NAME                      VM TYPE    CREATED        LAST UP      CPUS   MEMORY   DISK SIZE
podman-machine-default*   applehv    13 months ago  2 weeks ago  8      2GiB     100GiB
```

**Decision for this guide: Docker.** The podman machine has **2 GiB** of RAM, and this PoC runs seven
kind nodes plus two Cilium installs — it would not fit. Docker Desktop's VM can be resized (Step 1.3).

### Step 0.4 — check the host has room

**Why.** Each kind node is a container running a full kubelet. Seven of them, plus Cilium's agent on
every node, plus Envoy and the Hubble UI, is a real workload. If the host is small, find out now.

**Run:**

```bash
sysctl -n hw.ncpu hw.memsize
```

**Expected output** (this machine — 16 CPUs, then bytes of RAM):

```
16
34359738368
```

That is 16 CPU / 32 GB, comfortably enough.

**Check.** You want at least 8 CPU and 16 GB on the host to follow this guide as written. With less,
build only cluster `poc1` and skip Phase 4 (ClusterMesh).

---
## Step 1 — install and verify the toolchain

Four sub-steps, each run and verified on its own. Resist the urge to chain them with `&&`: when a
chain fails you have to work out *which* link broke, and Homebrew in particular prints a lot of
noise around the one line that matters.

### Step 1.1 — upgrade kind

**Why.** kind 0.33.0 ships newer node images and bug fixes. More importantly this PoC pins a node
image by digest, and older kind releases may not know the image format.

**Run:**

```bash
brew upgrade kind
```

**Expected output** (on this machine, which already had it):

```
Warning: kind 0.33.0 already installed
```

**Check — and a trap worth learning now.** Always verify with the binary itself, never with the
package manager's opinion:

```bash
kind --version
```

```
kind version 0.33.0
```

On this machine those two disagreed at first: brew said `0.33.0 already installed` while
`kind --version` said `0.25.0`. That means **`PATH` is finding a different binary than the one brew
manages**. Diagnose it like this:

```bash
which -a kind
```

```
/usr/local/bin/kind
```

```bash
ls -l /usr/local/bin/kind
```

```
lrwxr-xr-x@ 1 olasumbo admin 30 Sep 10 14:05 /usr/local/bin/kind -> ../Cellar/kind/0.33.0/bin/kind
```

`which -a` (note the `-a` — it lists *every* match, not just the first) plus `ls -l` on the result
tells you exactly which file runs and where it points. If you find a stale binary earlier in `PATH`,
remove it or fix the ordering; do not carry on with two versions installed.

### Step 1.2 — install the Cilium CLI

**Why.** `cilium` is the control tool for install, status, connectivity tests, Hubble enablement and
ClusterMesh. It also decides, by default, *which Cilium version* gets installed — so its version
matters to the whole PoC.

**Run:**

```bash
brew install cilium-cli
```

**Expected output** (tail; on an Intel Mac Homebrew now builds from source, which takes a couple of
minutes and is normal):

```
✔︎ Formula cilium-cli (0.20.0)
==> go build -o=/usr/local/Cellar/cilium-cli/0.20.0/bin/cilium ...
🍺  /usr/local/Cellar/cilium-cli/0.20.0: 10 files, 176.2MB, built in 2 minutes 13 seconds
```

A `Warning: Your Xcode (26.1.1) is outdated` line may appear. It is a warning, not an error — the
build completed.

**Check:**

```bash
cilium version --client
```

```
cilium-cli: v0.20.0 compiled with go1.27.1 on darwin/amd64
cilium image (default): v1.20.1
cilium image (stable): v1.20.1
```

Read the last two lines. **`cilium image (default): v1.20.1`** is the Cilium version this CLI will
install, and it is the version the whole guide is written against. If yours differs, note it — the
Kubernetes version pinned in Step 3 was chosen to match Cilium 1.20's support matrix.

### Step 1.3 — install the Hubble CLI

**Why.** `hubble` is the client for the flow-observability API. Hubble the *server* runs in the
cluster (we enable it in Step 5); this is the terminal client that reads flows from it.

**Run:**

```bash
brew install hubble
```

**Expected output** (tail):

```
✔︎ Bottle hubble (1.19.4)
🍺  /usr/local/Cellar/hubble/1.19.4: 11 files, 66.2MB
```

**Check:**

```bash
hubble version
```

```
hubble 1.19.4 compiled with go1.26.4 on darwin/amd64
```

### Step 1.4 — start the Docker daemon

**Why.** Every kind node is a Docker container. Nothing after this works without the daemon.

**Run:**

```bash
open -a Docker
```

That returns immediately — it only *launches* the app. The daemon takes roughly 30–60 seconds to
become usable. Do not race it; wait for it explicitly:

```bash
until docker info >/dev/null 2>&1; do sleep 5; done; echo "daemon is up"
```

**Check** — and record the VM's resources, because they decide whether seven nodes will fit:

```bash
docker info --format 'ServerVersion={{.ServerVersion}} CPUs={{.NCPU}} Mem={{.MemTotal}} Kernel={{.KernelVersion}}'
```

The `CPUs` and `Mem` here are **the Docker Desktop VM's**, not your host's. On macOS the default
allocation is often 2 CPU / 8 GB regardless of how large the host is — that is not enough for this
PoC. If you see less than 8 CPU or 16 GB, raise it in Docker Desktop → Settings → Resources, apply,
and wait for the daemon to restart before continuing.

The `Kernel` value matters later: the performance demo in Phase 3 needs **≥ 6.7** for netkit devices.
Note it down now.

---
