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

**Read these three first — each one costs an hour if you meet it cold.** They are documented in
place below, and summarised together in the [README](../README.md#findings-worth-your-attention)
and [FINDINGS.md](FINDINGS.md):

1. **The macOS host bridge is `bridge100` here, not the `bridge101` guides name.** macOS assigns
   the number; identify the interface by its `vmenet` member instead. → Step 3.5
2. **`CiliumLoadBalancerIPPool` is `cilium.io/v2` but `CiliumL2AnnouncementPolicy` is still
   `v2alpha1`.** They did not graduate together, so one manifest needs two apiVersions. → Step 8
3. **Finish every Docker Desktop setting BEFORE creating a cluster.** A multi-node kind cluster does
   not survive a Docker restart: container IPs are reassigned, etcd loses quorum against moved
   peers, and the cluster is unrecoverable. This build lost one that way. → **Step 2.7**

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

## Step 2 — size the Docker VM, and clear the decks

### Step 2.1 — find out how big the VM actually is

**Why.** Step 0.4 measured the *host*. Docker Desktop runs a Linux VM inside it, and only the VM's
share matters. On this machine the host had 32 GB and the VM had 7.66 GB.

**Run:**

```bash
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}} Kernel={{.KernelVersion}}'
```

**Output on this machine, before any change:**

```
CPUs=16 Mem=8221433856 Kernel=6.6.12-linuxkit
```

`8221433856` bytes is **7.66 GB**. Seven kind nodes with a Cilium agent each need roughly 8–10 GB on
their own, so this was not enough.

**Also note the kernel: `6.6.12-linuxkit`.** Write it down. Cilium's `netkit` device mode needs
**≥ 6.7**, so on this machine netkit is unavailable and the performance demo uses the bandwidth
manager and BIG TCP instead. That is a measured constraint, not a guess.

### Step 2.2 — see what is already running

**Why.** Existing clusters eat the same memory, and you must not delete someone's work by accident.

**Run:**

```bash
kind get clusters
```

**Output on this machine:**

```
demo-cluster
sck
```

Two pre-existing clusters. **Decide deliberately** whether to keep, stop, or delete them. Deleting
is not reversible. On this build they were no longer needed, so:

```bash
kind delete cluster --name demo-cluster
```

```
Deleting cluster "demo-cluster" ...
Deleted nodes: ["demo-cluster-control-plane"]
```

```bash
kind delete cluster --name sck
```

```
Deleting cluster "sck" ...
Deleted nodes: ["sck-control-plane"]
```

If you would rather keep them, `docker stop <node-container>` frees the memory without deleting
anything and `docker start` brings them back.

### Step 2.3 — raise the VM memory

**Why.** 16 GB leaves room for seven nodes and still leaves the host half its RAM.

**Back up the settings file first.** It is a single JSON file and a bad edit stops Docker starting:

```bash
cp ~/Library/Group\ Containers/group.com.docker/settings.json \
   ~/Library/Group\ Containers/group.com.docker/settings.json.bak-$(date +%Y%m%d-%H%M%S)
```

The supported route is the GUI: **Docker Desktop → Settings → Resources → Memory → 16 GB → Apply &
Restart.** If you prefer to edit the file, the key is `memoryMiB`:

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Group Containers/group.com.docker/settings.json'
d = json.loads(p.read_text()); d['memoryMiB'] = 16384
p.write_text(json.dumps(d, indent=2)); print('memoryMiB ->', d['memoryMiB'])
"
```

### Step 2.3b — enable kernel networking for UDP (macOS PREREQUISITE for routable container IPs)

> Architecture first: this step is layer 1 of [NETWORKING_DESIGN.md](../NETWORKING_DESIGN.md) §4.1 — the
> host↔VM link that the Mac's route (Step 3.5) will point at.

**Do this now, in the same edit as Step 2.3, so one restart applies both.**

**Why this exists.** On macOS, Docker containers run inside a Linux VM and **the container network is
not reachable from the host**. That is not a misconfiguration, it is the architecture. Measured on
this machine before the change:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 6 https://172.18.0.3:6443/version
```

```
000
```

```bash
netstat -rn -f inet | grep 172.18
```

```
(no output — there is no route to the kind network at all)
```

**Why it matters for this PoC.** Cilium's LB IPAM will hand LoadBalancer Services an address out of
the `kind` docker subnet (`172.18.0.0/16`), and the Gateway API demo depends on that. Those
addresses are perfectly reachable *inside* the cluster — but without this setting you cannot open
one in a browser on the laptop. Note carefully: **no in-cluster load balancer can fix this.**
kube-vip, MetalLB and Cilium LB IPAM would all allocate a `172.18.x` address and all be equally
unreachable, because the blocker is the host↔VM boundary, not the load balancer. The fix has to
happen on the Docker Desktop side.

**The feature.** Docker Desktop **4.26+** has a setting called *"kernel networking for UDP"*
(`kernelForUDP` in `settings.json`). With it on, Docker Desktop creates a `bridge101` interface on
macOS and an `eth1` interface inside the VM, which together make the container networks routable
from the host once you add a route.

**Check your version first** — below 4.26 this option does not exist:

```bash
defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString
```

```
4.27.2
```

**Enable it.** The supported route is the GUI: **Docker Desktop → Settings → Resources → Network →
"Enable kernel networking for UDP"**. Or, in the same settings file as Step 2.3:

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Group Containers/group.com.docker/settings.json'
d = json.loads(p.read_text()); d['kernelForUDP'] = True
p.write_text(json.dumps(d, indent=2)); print('kernelForUDP ->', d['kernelForUDP'])
"
```

```
kernelForUDP -> True
```

The route itself is added **after** the restart AND after the first cluster exists, in Step 3.5 — the `bridge101` interface and the
VM's `eth1` address do not exist until Docker has come back up with the setting on.

**Linux users: skip this step entirely.** Docker bridge networks are already routable from a Linux
host; this whole section exists only because of the macOS VM boundary.

### Step 2.4 — restart Docker, and WAIT FOR IT TO FULLY EXIT

**This is where this build went wrong, so read it before you act.**

```bash
osascript -e 'quit app "Docker"'
```

Then **wait until every Docker Desktop process is gone** before relaunching:

```bash
while pgrep -f "Docker Desktop" >/dev/null; do sleep 3; done; echo "fully exited"
```

**What went wrong here.** The build relaunched with `open -a Docker` while a check was still
reporting *"app still winding down"*. The new instance landed on a half-exited old one: the GUI came
up, but no VM was ever started. The symptom is a Docker Desktop window that looks alive while
`docker info` keeps failing, and the giveaway is in the logs —

```bash
tail -8 ~/Library/Containers/com.docker.docker/Data/log/host/com.docker.virtualization.log
```

```
[...][com.docker.virtualization][I] VM has stopped: context canceled
[...][com.docker.virtualization][I] Requesting VM termination
[...][com.docker.virtualization][I] vz.RunApplication returned
```

Nothing after `VM has stopped` means no new VM was ever asked for. If the app will not quit (it did
not here, four processes stayed), and the VM is already stopped with no containers running, it is
safe to terminate it:

```bash
pkill -f "Docker Desktop"
```

Then relaunch and wait properly:

```bash
open -a Docker
```

```bash
until docker info >/dev/null 2>&1; do sleep 5; done; echo "daemon is up"
```

**Check the new size took effect:**

```bash
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}} Kernel={{.KernelVersion}}'
```

```
CPUs=16 Mem=16769368064 Kernel=6.6.12-linuxkit
```

`16769368064` bytes = **15.62 GB**. Good. (The kernel is unchanged — resizing memory does not change
the VM image, so netkit is still unavailable.)

---

## ⚠ Step 2.7 — ORDERING: finish ALL Docker settings BEFORE creating any cluster

**Read this before Step 3. This build learned it the expensive way.**

A multi-node kind cluster **does not survive a Docker Desktop restart.** Docker reassigns container
IP addresses on start, in whatever order containers happen to come up, and a kind cluster's etcd
peer URLs and API server certificate SANs are written around the addresses the nodes had at
creation time.

Measured here. Before the restart, and after it:

| Container | Before | After |
|---|---|---|
| `poc1-control-plane` | 172.18.0.3 | **172.18.0.7** |
| `poc1-control-plane2` | 172.18.0.4 | **172.18.0.2** |
| `poc1-control-plane3` | 172.18.0.6 | **172.18.0.5** |
| `poc1-external-load-balancer` | 172.18.0.7 | **172.18.0.6** |

Every container came back up, and the cluster was still dead:

```
kube-apiserver ... Exited (attempt 5)
E run.go:72] "command failed" err="error creating storage factory: context deadline exceeded"
W grpc: addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2379" ...}
```

etcd could not form a quorum because its peers' addresses had moved, so the API server could not
reach its datastore. The cluster had to be deleted and recreated.

**So the rule is:** make **every** Docker Desktop change — memory (2.3), `kernelForUDP` (2.3b) —
**before** Step 3, and apply them in **one** restart. After that, avoid restarting Docker for the
life of the cluster. If you must, expect to `kind delete cluster` and rebuild.

**A silver lining that validates an earlier decision.** Across three creations of `poc1` the load
balancer's IP was `.7`, then `.6`, then `.2` — while its DNS name, `poc1-external-load-balancer`,
never changed. That is a second, independent reason Step 5 passes Cilium the **name** and not the
address: had the IP been baked into `cilium/values-poc1.yaml`, every rebuild would have broken it.

---

## Step 3 — create the poc1 cluster

**Why.** `clusters/poc1.yaml` is the whole cluster definition: three control planes, two workers, no
default CNI, no kube-proxy, explicit CIDRs and a digest-pinned node image. Read its comments — every
line in it is a decision.

**Run:**

```bash
kind create cluster --config clusters/poc1.yaml
```

**Expected output:**

```
Creating cluster "poc1" ...
 ✓ Ensuring node image (kindest/node:v1.36.4) 🖼️
 ✓ Preparing nodes 📦 📦 📦 📦 📦
 ✓ Configuring the external load balancer ⚖️
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining more control-plane nodes 🎮
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-poc1"
```

Note the line **`Configuring the external load balancer`** — that only appears with more than one
control plane, and it matters in Step 5.

**Check — and do not panic at the result:**

```bash
kubectl --context kind-poc1 get nodes
```

```
NAME                  STATUS     ROLES           AGE   VERSION
poc1-control-plane    NotReady   control-plane   64s   v1.36.4
poc1-control-plane2   NotReady   control-plane   20s   v1.36.4
poc1-control-plane3   NotReady   control-plane   10s   v1.36.4
poc1-worker           NotReady   <none>          7s    v1.36.4
poc1-worker2          NotReady   <none>          7s    v1.36.4
```

**Every node is `NotReady`, and that is correct.** A node reports Ready only once a CNI is running,
and we deliberately disabled kind's. Do not debug this; install Cilium. The version column must read
`v1.36.4` — if it says something else, the pinned image in the config was not used.

**Capture the "before" state for the kube-proxy demo now**, while it is still true:

```bash
kubectl --context kind-poc1 -n kube-system get daemonset
```

```
No resources found in kube-system namespace.
```

No kube-proxy, and no kindnet. Later, when Cilium reports `KubeProxyReplacement: True`, this is the
evidence that there was never anything running alongside it.

---

## Step 3.5 — route the docker network from macOS

> The design behind this step — one subnet, two reserved ranges, why the Mac becomes a router and why a
> Linux server needs no route — is [NETWORKING_DESIGN.md](../NETWORKING_DESIGN.md) §1–§5. Read it once;
> this step is its §4.3–§4.4 executed value by value.

**Two preconditions:** Step 2.3b (`kernelForUDP`) is on and Docker has restarted, **and** a cluster
exists. That second one is easy to miss — the `kind` docker network is created by kind when it
builds its *first* cluster, so on a fresh machine there is nothing to route to until Step 3 has
run. (It then persists, even after `kind delete cluster`.)

The whole step is one command, but **do not copy the numbers** — both are specific to a machine.
This section derives each one.

```bash
sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

### Anatomy of the command

| Part | Means | Where it comes from |
|---|---|---|
| `route` | macOS routing table tool | built in |
| `-n` | print addresses numerically, do not try to resolve names | — |
| `add` | add a route (`delete` removes it) | — |
| `-net` | this is a **network** route, not a single `-host` route | — |
| `172.18.0.0/16` | **DESTINATION** — the subnet to route | the `kind` docker network (3.5.1) |
| `192.168.64.2` | **GATEWAY** — who to send it to | the Docker VM's address (3.5.2) |

Read as a sentence: *"to reach anything in 172.18.0.0/16, hand the packet to 192.168.64.2."*

### Step 3.5.1 — get the DESTINATION: the docker network subnet

This is the network your kind nodes live on.

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

```
172.18.0.0/16 fc00:f853:ccd:e793::/64
```

Take the **IPv4** one: `172.18.0.0/16`. (The second is IPv6 and this guide routes IPv4 only.)

Sanity-check it against a real node — the node address must fall inside that subnet:

```bash
docker inspect poc1-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

```
172.18.0.6
```

`172.18.0.6` is inside `172.18.0.0/16`. Good.

> **Your subnet may differ.** Docker picks from `172.17.0.0/16` upward as networks are created, so
> on another machine `kind` may be `172.19.0.0/16` or higher. Always read it; never assume 172.18.

### Step 3.5.2 — get the GATEWAY: the Docker VM's address

With `kernelForUDP` on, Docker Desktop puts the VM on a bridge shared with the host. You need the
**VM's** address on that bridge.

**First find the bridge** (the host side), and note that **the number is not portable** — guides
say `bridge101`, this machine got `bridge100`:

```bash
ifconfig -l | tr ' ' '\n' | grep -E '^bridge'
```

```
bridge0
bridge100
```

Identify the right one by its **`vmenet` member** — that is the link to the VM — rather than by its
number:

```bash
ifconfig bridge100 | grep -E 'inet |member'
```

```
 inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
 member: vmenet0 flags=10803<LEARNING,DISCOVER,PRIVATE,CSUM>
```

`192.168.64.1` is the **host's** address on that segment. The gateway you want is the **VM's**
address on the same segment — usually `.2`, but read it rather than guessing:

```bash
docker run --rm --net=host --privileged busybox sh -c "ip -4 addr show eth1 | grep -o 'inet [0-9.]*'"
```

```
inet 192.168.64.2
```

That container runs with `--net=host`, which on Docker Desktop means *the VM's* network namespace,
not macOS's — which is exactly why it can see `eth1`. `--privileged` is needed to read it.

So: **gateway = `192.168.64.2`**, on the same `192.168.64.0/24` segment as the host's
`192.168.64.1`. If your two addresses are not on the same subnet, something is wrong — stop and
recheck Step 2.3b.

### Step 3.5.3 — derive both automatically

Rather than transcribing, let the shell compute them:

```bash
DOCKER_NET=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
VM_IP=$(docker run --rm --net=host --privileged busybox sh -c "ip -4 addr show eth1 | grep -o 'inet [0-9.]*'" | awk '{print $2}')
echo "destination = $DOCKER_NET"
echo "gateway     = $VM_IP"
echo "command     = sudo route -n add -net $DOCKER_NET $VM_IP"
```

```
destination = 172.18.0.0/16
gateway     = 192.168.64.2
command     = sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

Then run the printed command.

### Step 3.5.4 — run it

**`sudo` cannot prompt for a password from a non-interactive shell** (including Claude Code's `!`
prefix). You will get:

```
sudo: a terminal is required to read the password; either use the -S option to read from standard
input or configure an askpass helper
```

That is not a Docker problem. Run the command in a normal **Terminal** window:

```bash
sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

### Step 3.5.5 — verify

```bash
netstat -rn -f inet | grep '^172.18'
```

```
172.18             192.168.64.2       UGSc            bridge100
```

Read the flags: `U` up, `G` gateway, `S` static, `c` clones. The `Netif` column confirms it is
going out of the bridge from 3.5.2.

Now prove it end to end. At this point in the guide the only thing on that network is the cluster
itself, so test a **node IP** — take one from Step 3.5.1:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://172.18.0.6:6443/version
```

```
200
```

Compare with Step 2.3b, where the identical request returned `000`.

Once **Step 8** has assigned a LoadBalancer address, the same route carries that too — verified
later in the guide:

```bash
curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' http://172.18.255.200/
```

```
200 in 0.007111s
```

Compare with Step 2.3b, where the same node request returned `000` and the routing table had no
`172.18` entry at all.

### What the route actually makes your Mac: a router, with one hop into the overlay

It helps to see this the way you would see any other network, because it *is* one. After Step 3.5
your laptop has a static route, the Docker VM is the next hop, and Cilium answers on the far side.
Nothing about it is special to kind or Cilium — it is the same three pieces a branch-office router
has: a route, a next hop, and something at the destination that answers ARP.

```bash
netstat -rn -f inet | grep -E '^Destination|^172\.18'
```

```
Destination        Gateway            Flags               Netif
172.18             192.168.64.2       UGSc            bridge100
```

One `/16` route covers **every** LoadBalancer address, in both pools, and every node — it never
needs editing when a pool is added or a Gateway moves.

**Make the hop visible.** `traceroute` to a Gateway address and to a Services-pool address:

```bash
traceroute -n -m 4 -q 1 -w 2 172.18.255.240     # a Gateway (gateway-pool)
traceroute -n -m 4 -q 1 -w 2 172.18.255.201     # hubble-ui  (services pool)
```

```
traceroute to 172.18.255.240, 4 hops max
 1  192.168.64.2  1.302 ms        <- the Docker VM: your next hop
 2  *
 3  *

traceroute to 172.18.255.201, 4 hops max
 1  192.168.64.2  1.023 ms        <- same next hop
 2  *
```

Read hop 1 and the silence after it together. **Hop 1 is the VM**, reached over `bridge100` —
the "router" you added. After that there is **no further hop to show**: inside the VM the packet
lands on the `kind` docker bridge, and the LoadBalancer address is not a host with a routing
stack, it is an address a Cilium node **answers ARP for** (L2 announcement). The reply comes from a
node interface directly; there is nothing in between to decrement the TTL, so traceroute prints
`*`. That is normal for an L2-announced address and is *not* a dropped route.

**Which node is answering, right now**, is the L2 announcement lease — the "router inside the
overlay" that moves if a node dies:

```bash
kubectl -n kube-system get lease -o custom-columns='LEASE:.metadata.name,HOLDER:.spec.holderIdentity' | grep l2announce
```

```
cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-control-plane3
cilium-l2announce-kube-system-hubble-ui               poc1-worker
cilium-l2announce-routes-cilium-gateway-routes-gw     poc1-control-plane3
```

So a request to `https://hubble.poc.local` travels: **Mac → `bridge100` → VM `eth1` → docker bridge
→ ARP answered by `poc1-control-plane3` → Cilium eBPF → the Gateway's Envoy → the pod.** Every hop
is observable with an ordinary tool, which is the point of writing it down.

**Why the Gateway range matters to the router view.** `172.18.255.240–250` is reserved for
Gateways (`cilium/lb-ippool-poc1.yaml`). That is the range DNS points at (`*.poc.local`), the range a
firewall rule would name, and the range a bookmark holds — and because only Gateway-owned Services
can draw from it, "this address is a Gateway" is true by construction rather than by luck.
Reference: [Cilium LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/).

### Managing the route

```bash
sudo route -n delete -net 172.18.0.0/16          # remove it
netstat -rn -f inet | grep '^172'                # list what is routed
```

**It is not persistent.** It is lost on reboot, and must be re-added whenever the Docker VM
restarts or its address changes. Re-run 3.5.3 to re-derive — the VM address can move.

### Step 3.5b — the no-sudo alternative (and why you might keep both)

If you cannot or would rather not use `sudo`, publish a single service through a proxy container on
the docker network instead. Docker's normal port publishing crosses the VM boundary, so no route is
involved:

```bash
docker run -d --name hubble-ui-proxy --network kind -p 18080:80 --restart unless-stopped \
  alpine/socat tcp-listen:80,fork,reuseaddr tcp-connect:172.18.255.200:80
```

```bash
curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' http://localhost:18080/
```

```
200 in 0.004836s
```

|  | Route (2.6) | Proxy container (2.6b) |
|---|---|---|
| Needs `sudo` | yes | no |
| Survives reboot | **no** — re-add each time | yes, with `--restart unless-stopped` |
| Reaches | every container and LB address | one service per proxy container |
| URL | `http://172.18.255.200/` | `http://localhost:18080/` |

They are complementary. The route is the better daily experience; the proxy is useful insurance
precisely because the route does not persist.

---

## Step 4 — find the API server endpoint Cilium must use

**Why this step exists at all.** With `kubeProxyMode: none` there is no kube-proxy, so the
`kubernetes.default` Service does not work yet — that Service is implemented *by* Cilium, which is
not running. Cilium therefore has to be handed a real API server address at install time. Getting
this wrong is the single most likely way to lose an hour, so it gets its own step.

**Run:**

```bash
docker ps --filter "name=poc1" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

```
NAMES                         IMAGE                      STATUS
poc1-external-load-balancer   envoyproxy/envoy:v1.36.2   Up About a minute
poc1-control-plane3           kindest/node:v1.36.4       Up About a minute
poc1-worker                   kindest/node:v1.36.4       Up About a minute
poc1-worker2                  kindest/node:v1.36.4       Up About a minute
poc1-control-plane            kindest/node:v1.36.4       Up About a minute
poc1-control-plane2           kindest/node:v1.36.4       Up About a minute
```

Two things to take from this:

1. There is a sixth container, `poc1-external-load-balancer`. **That** is the API endpoint to use,
   not any one control-plane node — it is the only address that stays valid when a control plane
   goes away, which is the entire point of having three.
2. On kind 0.33.0 it runs **Envoy**, not HAProxy. Many guides (and an earlier draft of this one) say
   HAProxy. Check, do not assume.

**Use its DNS NAME, `poc1-external-load-balancer` — not its IP.** The next step explains why, with
the evidence, because this build got it wrong first.

---

## Step 5 — install Cilium

> **`cilium/values-poc1.yaml` carries `hubble.relay.tls.server.enabled/mtls: true` since 2026-09-12** —
> rendered proof that the Helm certificate method issues `hubble-relay-server-certs`, `hubble-relay-client-certs`
> and `hubble-ui-client-certs` at install and the relay Service is 443 (demo 25 Part 5g). Nothing in this
> step's commands changes; Step 6 configures the CLI.

### Step 5.1 — add the chart repository

```bash
helm repo add cilium https://helm.cilium.io/
```

```
"cilium" has been added to your repositories
```

```bash
helm repo update cilium
```

```
...Successfully got an update from the "cilium" chart repository
Update Complete. ⎈Happy Helming!⎈
```

**Check the version you are about to install actually exists:**

```bash
helm search repo cilium/cilium --versions | head -3
```

```
NAME          CHART VERSION  APP VERSION  DESCRIPTION
cilium/cilium 1.20.1         1.20.1       eBPF-based Networking, Security, and Observability
cilium/cilium 1.20.0         1.20.0       eBPF-based Networking, Security, and Observability
```

### Step 5.2 — install

> **Day-1 tuning is in the values file, on purpose.** `cilium/values-poc1.yaml` sets
> `bpf.masquerade: true`, which switches masquerading to eBPF and with it turns on eBPF **host
> routing** (`Host: BPF` instead of `Legacy`): packets leaving a pod go eBPF → NIC without
> traversing netfilter. The chart default leaves that off, and enabling it later costs an agent
> restart and a 2–3 minute Gateway outage. Why, what it measured, and how to prove it is on:
> **[docs/TUNING.md](TUNING.md)**.

`cilium/values-poc1.yaml` holds everything that can be decided in advance. Only the API server
address is passed on the command line, because it is not knowable until the cluster exists.

**Run:**

```bash
helm install cilium cilium/cilium \
  --version 1.20.1 \
  --namespace kube-system \
  --kube-context kind-poc1 \
  -f cilium/values-poc1.yaml \
  --set k8sServiceHost=poc1-external-load-balancer \
  --set k8sServicePort=6443
```

**Expected output:**

```
NAME: cilium
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
NOTES:
You have successfully installed Cilium with Hubble Relay and Hubble UI.
```

A warning about Hubble Relay TLS being disabled is expected for a local PoC.

### Step 5.3 — THE FAILURE THIS BUILD HIT, and how it was diagnosed

This section is kept deliberately. The first install used the load balancer's **IP** instead of its
DNS name, and the debugging path is more useful than the fix.

**Symptom.** `cilium status --wait` never converged:

```
DaemonSet cilium   Desired: 5, Unavailable: 5/5
Containers: cilium   Pending: 5
Cluster Pods: 0/5 managed by Cilium
```

**Step 1 — ask which container is failing, not "why is the pod pending".**

```bash
kubectl --context kind-poc1 -n kube-system describe pod <cilium-pod> | sed -n '/Events:/,$p'
```

```
Warning  BackOff  74s (x2 over 2m29s)  kubelet  Back-off restarting failed container config in pod cilium-...
```

It is the `config` **init** container, so nothing later ever starts.

**Step 2 — read that container's logs specifically** (`-c config`, or you get the wrong container):

```bash
kubectl --context kind-poc1 -n kube-system logs <cilium-pod> -c config --tail=8
```

```
level=info msg="Establishing connection to apiserver" ipAddr=https://172.18.0.7:6443
level=info msg="Establishing connection to apiserver" ipAddr=https://172.18.0.7:6443
level=info msg="Establishing connection to apiserver" ipAddr=https://172.18.0.7:6443
```

Looping forever on the address we supplied.

**Step 3 — test the claim. Is the endpoint really unreachable?**

```bash
docker exec poc1-control-plane sh -c "curl -sk -o /dev/null -w 'http_code=%{http_code} time=%{time_total}s\n' --max-time 8 https://172.18.0.7:6443/version"
```

```
http_code=200 time=0.009367s
```

**200 in 9 milliseconds.** The API server is up and reachable at that exact address. So the problem
is not the network — and the `-k` in that command is the clue to what it *is*, because `-k` skips
certificate verification.

**Step 4 — check the certificate, since that is what `-k` skipped.**

```bash
docker exec poc1-control-plane sh -c "openssl s_client -connect 172.18.0.7:6443 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A3 'Subject Alternative Name'"
```

```
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc,
    DNS:kubernetes.default.svc.cluster.local, DNS:localhost, DNS:poc1-control-plane2,
    DNS:poc1-external-load-balancer,
    IP Address:10.11.0.1, IP Address:172.18.0.4, IP Address:127.0.0.1
```

**There it is.** `DNS:poc1-external-load-balancer` is present; the load balancer's own IP
`172.18.0.7` is **not**. A client that verifies the certificate — which Cilium does, and `curl -k`
does not — rejects the IP and accepts the name.

**Step 5 — prove both directions before changing anything**, using the cluster's real CA:

```bash
docker exec poc1-control-plane sh -c '
CA=/etc/kubernetes/pki/ca.crt
echo -n "by IP  : "; curl -s -o /dev/null -w "%{http_code}\n" --cacert $CA --max-time 8 https://172.18.0.7:6443/version || echo "TLS FAILED"
echo -n "by DNS : "; curl -s -o /dev/null -w "%{http_code}\n" --cacert $CA --max-time 8 https://poc1-external-load-balancer:6443/version || echo "TLS FAILED"
'
```

```
by IP  : 000
TLS FAILED
by DNS : 200
```

**The fix**, which is why Step 5.2 already tells you to use the name:

```bash
helm upgrade cilium cilium/cilium \
  --version 1.20.1 --namespace kube-system --kube-context kind-poc1 \
  -f cilium/values-poc1.yaml \
  --set k8sServiceHost=poc1-external-load-balancer \
  --set k8sServicePort=6443
```

```bash
kubectl --context kind-poc1 -n kube-system rollout restart daemonset/cilium
```

```bash
kubectl --context kind-poc1 -n kube-system rollout restart deployment/cilium-operator
```

The logs then read:

```
level=info msg="Connected to apiserver" module=k8s-client
```

**The transferable lesson.** When something cannot reach an API server that is demonstrably up,
**check the certificate SANs before you touch the network.** `curl -sk` succeeding while the real
client fails is the signature of a TLS-verification problem, because `-k` disables exactly the check
the client is performing. Reach for `openssl x509 -text` early.

---

### Step 5.4 — "is the service mesh on?" — what a plain install enables, and what this PoC adds

"Cilium Service Mesh" is not one feature with one switch. It is Cilium's Envoy-based L7 layer plus
the things built on it, each with its own helm value and its own default. Read from the 1.20.1
chart (`helm show values cilium/cilium --version 1.20.1`) and from poc1's release, 2026-09-12:

| Component | Chart default | poc1 | Where it is proven |
|---|---|---|---|
| **`l7Proxy`** — the Envoy proxy that makes HTTP-aware network policy work; the mesh *datapath* | **on** | on | demo 02 (`POST` allowed, `PUT` denied, same pods) |
| **Envoy as its own `cilium-envoy` DaemonSet** (`envoy.enabled`, the default mode in 1.20) | on | `cilium-envoy` 5/5 | demo 05 ("every hop is Cilium") |
| **`hubble.enabled`** — observability | **on** (`relay`, `ui` off) | on, with relay, UI and flow export | demos 01, 10 |
| `gatewayAPI.enabled` — Cilium as the Gateway controller (ingress) | off | **on** (`+ enableAlpn`) | demos 05, 09 |
| `ingressController.enabled` — the older Ingress support | off | off (Gateway API replaces it) | — |
| `encryption.enabled` — WireGuard / IPsec / ztunnel | off | off, by decision | demo 04 (WireGuard proven, left off) |
| `authentication.mutual…` — the deprecated "mutual auth" | off | off, not adopting | demo 13, `docs/summary/MTLS_EVALUATION.md` |
| `kubeProxyReplacement` | off | **on** (required for Gateway API) | demo 03 |

The honest sentence: **the service-mesh *datapath* (Envoy + L7 policy) is on by default; the
service-mesh *features* people usually mean — ingress via Gateway API, encryption, mTLS, the
observability UI — are off by default and enabled one value at a time.** poc1 has all of them on
except encryption and mTLS, each by a recorded decision.

One practical consequence: because `l7Proxy` and Envoy are on by default, any
`CiliumNetworkPolicy` with an `http:` rule *automatically* steers that traffic through Envoy —
there is no sidecar to inject and nothing to enable per workload. That is the real difference
from sidecar meshes, and it is the property ztunnel would break (demo 13, Part 4).

## Step 6 — verify the install

> **Before the first `hubble` command (2026-09-12):** the day-one values put the relay on mutual TLS
> (gotcha #75), so configure the CLI once — it fetches the client certificate the chart issued and
> writes the TLS settings into `~/.config/hubble/config.yaml`; from here on every `hubble …` in this
> document and in the demos works exactly as written (port-forwards to the relay use `4245:443`):
>
> ```bash
> scripts/hubble-tls.sh --configure kind-poc1        # after Step 9: --configure kind-poc1 kind-poc2
> hubble config view | grep ^tls                     # tls: true, the CA, the client certificate
> ```

### Step 6.1 — Cilium's own status

```bash
cilium status --context kind-poc1 --wait
```

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet cilium          Desired: 5, Ready: 5/5, Available: 5/5
Deployment cilium-operator  Desired: 1, Ready: 1/1, Available: 1/1
```

**Be patient here.** Immediately after a rollout restart this legitimately reports errors for
`cilium-envoy`, `hubble-relay` and `hubble-ui` while pods reschedule. Re-run it before concluding
anything is broken — on this build a run showing `Envoy DaemonSet: 1 errors` was green a minute
later with no intervention.

### Step 6.2 — the nodes should now be Ready

```bash
kubectl --context kind-poc1 get nodes
```

```
NAME                  STATUS   ROLES           AGE     VERSION
poc1-control-plane    Ready    control-plane   9m13s   v1.36.4
poc1-control-plane2   Ready    control-plane   8m29s   v1.36.4
poc1-control-plane3   Ready    control-plane   8m19s   v1.36.4
poc1-worker           Ready    <none>          8m16s   v1.36.4
poc1-worker2          Ready    <none>          8m16s   v1.36.4
```

This is the payoff from Step 3: the nodes were `NotReady` purely for want of a CNI, and installing
one fixed all five.

### Step 6.3 — confirm kube-proxy really is replaced

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep -E 'KubeProxyReplacement|Cilium:|Routing:|Masquerading:'
```

```
KubeProxyReplacement:    True   [eth0  172.18.0.4 ... (Direct Routing)]
Cilium:                  Ok     1.20.1 (v1.20.1-7d68cfb3)
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]

> Captured before `bpf.masquerade: true` was adopted (demo 11). On a fresh install from the
> values file these two lines read `Host: BPF` and `Masquerading: BPF [eth0] …` — docs/TUNING.md §1.
```

`KubeProxyReplacement: True` is the headline. Read it together with the `No resources found` from
Step 3: services are being load-balanced in eBPF, and there is no kube-proxy anywhere to be doing it
instead.

---

## Step 8 — LoadBalancer addresses without a cloud (and without MetalLB or kube-vip)

> The two pools applied here are **poc1's block** of the reserved range in [NETWORKING_DESIGN.md](../NETWORKING_DESIGN.md)
> §0 and §3 — `172.18.255.192/26`: `kind-docker-pool` `.255.200–239` for plain Services, `gateway-pool`
> `.255.240–250` for Gateway API only. **Every cluster gets a block of its own** (poc2's is Step 9.2b): the
> clusters share the bridge, never an address.

**Why this is needed.** kind has no cloud provider, so a `type: LoadBalancer` Service stays
`<pending>` forever and a Gateway never gets an address. The reflex is to install MetalLB or
kube-vip. **Neither is used here:** Cilium 1.20 ships both halves itself — **LB IPAM** assigns the
address, **L2 announcements** answer ARP for it — so this is one fewer component and it demonstrates
a Cilium capability rather than working around a gap.

**Where the addresses come from.** The nodes live on the `kind` docker bridge, so LoadBalancer
addresses must be on that same segment. Confirm the subnet:

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

```
172.18.0.0/16 fc00:f853:ccd:e793::/64
```

Docker allocates container addresses from the **bottom** of that range upward (`.2`, `.3`, `.4`…),
so `cilium/lb-ippool-poc1.yaml` takes a slice from the **top**. They can never collide. The slice is split
into **two pools with complementary selectors** — `172.18.255.240–250` reserved for Gateway-owned
Services (label `io.cilium.gateway/owning-gateway` Exists), `172.18.255.200–239` for everything
else — so a Gateway's address is in the Gateway range by construction. Reference:
[Cilium LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/); the pool file quotes the two
rules that matter (selector match is required for a pinned IP; overlapping pools conflict).

```bash
kubectl --context kind-poc1 apply -f cilium/lb-ippool-poc1.yaml
```

**An API version trap.** Applying the pool as `cilium.io/v2alpha1` produces:

```
Warning: cilium.io/v2alpha1 CiliumLoadBalancerIPPool is deprecated; use cilium.io/v2
```

but the L2 announcement policy is **still v2alpha1-only** in this release. They did not graduate
together. Check, do not assume:

```bash
kubectl --context kind-poc1 api-resources | grep -iE 'loadbalancerippool|l2announcement'
```

```
ciliuml2announcementpolicies   l2announcement   cilium.io/v2alpha1   false   CiliumL2AnnouncementPolicy
ciliumloadbalancerippools      ippools,...      cilium.io/v2         false   CiliumLoadBalancerIPPool
```

**Check the pool is healthy:**

```bash
kubectl --context kind-poc1 get ciliumloadbalancerippool
```

```
NAME               DISABLED   CONFLICTING   IPS AVAILABLE   AGE
kind-docker-pool   false      False         51              18s
```

`CONFLICTING: False` and a non-zero `IPS AVAILABLE` are what you want.

### Try it: give Hubble UI a real address

```bash
kubectl --context kind-poc1 -n kube-system patch svc hubble-ui -p '{"spec":{"type":"LoadBalancer"}}'
```

```bash
kubectl --context kind-poc1 -n kube-system get svc hubble-ui
```

```
NAME        TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
hubble-ui   LoadBalancer   10.11.186.239   172.18.255.200   80:32537/TCP   2m33s
```

**`EXTERNAL-IP: 172.18.255.200`** — the first address from the pool, assigned in seconds.

**Prove it serves, from the docker network** (this works whether or not the macOS route from Step
2.6 is in place, so it isolates "the load balancer works" from "my laptop can reach it"):

```bash
docker run --rm --network kind curlimages/curl:latest   -s -o /dev/null -w 'http_code=%{http_code} time=%{time_total}s
' http://172.18.255.200/
```

```
http_code=200 time=0.003746s
```

**From the macOS browser**, `http://172.18.255.200/` works only once Step 3.5's route is added.
Without it you will get a timeout — and that is a host routing problem, not a Cilium one. The two
tests above tell those apart: if the container test returns 200 and the browser does not, the
cluster is fine and the route is missing.

---

## Step 8b — Gateway API flags, and the rule for operator-side flags

Gateway API itself is switched on in **demo 05** (CRDs first, then two helm values), so it is not
repeated here — but the rule it teaches applies to every later upgrade in this guide:

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  --reuse-values --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true
kubectl -n kube-system rollout restart deployment/cilium-operator daemonset/cilium
```

- **`gatewayAPI.enableAlpn=true` goes on with `gatewayAPI.enabled`.** Off by default; without it
  the Gateway's HTTPS listeners negotiate no ALPN and gRPC over TLS fails for any grpc-go ≥ 1.67
  client while older tools (`grpcurl`) still report success — gotcha #33, found in demo 09.
- **A helm value that only changes `cilium-config` does not restart the operator.** The operator
  reads its flags at startup; `helm upgrade` rewrites the ConfigMap, the Deployment template is
  unchanged, `kubectl rollout status` says "successfully rolled out", and the same pod keeps the old
  flags. Measured in demo 09: 60 s of polling after the upgrade, no change; ALPN appeared only after
  `rollout restart deploy/cilium-operator`. The same rule bit once before with a CRD (gotcha #28).
  **After any operator-side flag change, restart the operator and prove the effect** — here with
  `echo | openssl s_client -connect <gateway>:443 -servername <host> -alpn h2,http/1.1 | grep ALPN`.

## Step 9 — the second cluster and ClusterMesh

> After poc2 is installed: `scripts/hubble-tls.sh --configure kind-poc1 kind-poc2` — until Step 9.3a
> each cluster has its own CA, and the CLI needs both in `tls-ca-cert-files`; after it, one root.

Only needed for demo 07. It adds two more nodes, so check headroom first:
`docker stats --no-stream --format '{{.MemUsage}}'`.

### Step 9.1 — create poc2

```bash
kind create cluster --config clusters/poc2.yaml
```

```bash
docker ps --filter "name=poc2" --format '{{.Names}}'
```

```
poc2-control-plane
poc2-worker
```

**Note what is NOT there: no `poc2-external-load-balancer`.** With a single control plane kind
creates none. That changes one value in the next step, and it is the simpler of the two cases.

### Step 9.2 — install Cilium on poc2

```bash
helm install cilium cilium/cilium --version 1.20.1 \
  --namespace kube-system --kube-context kind-poc2 \
  -f cilium/values-poc2.yaml \
  --set k8sServiceHost=poc2-control-plane \
  --set k8sServicePort=6443
```

`k8sServiceHost` is the **control-plane node**, not a load balancer — because there is no load
balancer. **The naming rule from Step 5.3 still applies:** pass the NAME. The certificate lists
`DNS:poc2-control-plane`, and Docker reassigns addresses on restart.

Check the CIDR is poc2's own, proving the clusters do not overlap:

```bash
kubectl --context kind-poc2 -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep IPAM
```

```
IPAM:  IPv4: 6/254 allocated from 10.20.1.0/24,
```

`10.20.x` — poc2's subnet. poc1 uses `10.10.x`.

### Step 9.2b — poc2's own LoadBalancer block

A cluster is a complete system before it joins any mesh, and its service addresses are part of that.
poc2 announces on the same docker bridge as poc1, and LB IPAM allocates per cluster, so poc2 gets
**its own /26** of the reserved range — `172.18.255.128/26`, the same layout as poc1's block one /26
lower (NETWORKING_DESIGN.md §3, item 4) — never poc1's file:

```bash
kubectl --context kind-poc2 apply -f cilium/lb-ippool-poc2.yaml
kubectl --context kind-poc2 get ciliumloadbalancerippool
```

```
NAME               DISABLED   CONFLICTING   IPS AVAILABLE   AGE
gateway-pool       false      False         11              5s
kind-docker-pool   false      False         40              5s
```

`cilium/values-poc2.yaml` turns `l2announcements` on for exactly this (with the same client rate
limit as poc1); an earlier revision left it off "to keep the laptop small", which made poc2 an
appendage of poc1. The CI lab (`scripts/lab-up.sh`) applies `cilium/lb-ippool-<cluster>.yaml` for
every cluster and refuses to bring one up without its file.

### Step 9.3 — establish trust BEFORE connecting

**Two routes. Pick one before you go any further — trust is a prerequisite of joining, not
something to retrofit.**

| Route | Use when | Where |
|---|---|---|
| **A — enterprise CA with cert-manager** | anything beyond a throwaway lab | Step 9.3a, and [demo 08](../demos/08-certmanager-ca/README.md) |
| **B — copy Cilium's self-signed CA** | quick start only | Step 9.3b |

Route A is the one to learn. Route B is kept because Cilium's own docs show it and you will meet
it, but it generates the CA as a side effect of installing a CNI, distributes it by hand with no
record, and renews leaf certificates on a CronJob you do not control.

### Step 9.3a — ROUTE A: an enterprise root CA with cert-manager (recommended)

Full walkthrough in [demo 08](../demos/08-certmanager-ca/README.md); the sequence is:

```bash
# 1. cert-manager in BOTH clusters — each issues its own leaf certs locally
helm repo add jetstack https://charts.jetstack.io && helm repo update jetstack
for ctx in kind-poc1 kind-poc2; do
  helm install cert-manager jetstack/cert-manager --version v1.21.1 \
    --namespace cert-manager --create-namespace --kube-context "$ctx" --set crds.enabled=true
done
```

```bash
# 2. the root CA, in poc1 (bootstrap Issuer -> root Certificate -> ClusterIssuer "ca-issuer")
kubectl --context kind-poc1 apply -f demos/08-certmanager-ca/01-root-ca-poc1.yaml
```

```bash
# 3. distribute ONLY the root Secret to poc2, then create the SAME issuer name there
#    (the Python rebuild is deliberate: the obvious sed pipeline is a GNU-ism BSD sed rejects)
kubectl --context kind-poc1 -n cert-manager get secret clustermesh-root-ca -o json \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","type":s.get("type","kubernetes.io/tls"),"metadata":{"name":s["metadata"]["name"],"namespace":"cert-manager"},"data":s["data"]}))' \
  | kubectl --context kind-poc2 apply -f -
kubectl --context kind-poc2 apply -f demos/08-certmanager-ca/02-issuer-poc2.yaml
```

```bash
# 4. verify ONE trust anchor before going further — compare, do not assume
for c in kind-poc1 kind-poc2; do
  kubectl --context $c -n cert-manager get secret clustermesh-root-ca \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
done
```

The two fingerprints must be **identical**.

```bash
# 5. point Cilium at the issuer, in BOTH clusters
for ctx in kind-poc1 kind-poc2; do
  helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context "$ctx" --reuse-values \
    --set clustermesh.apiserver.tls.auto.enabled=true \
    --set clustermesh.apiserver.tls.auto.method=certmanager \
    --set clustermesh.apiserver.tls.auto.certManagerIssuerRef.group=cert-manager.io \
    --set clustermesh.apiserver.tls.auto.certManagerIssuerRef.kind=ClusterIssuer \
    --set clustermesh.apiserver.tls.auto.certManagerIssuerRef.name=ca-issuer
done
```

```bash
# 6. confirm the mesh certs chain to YOUR root before joining
for c in kind-poc1 kind-poc2; do
  kubectl --context $c -n kube-system get secret clustermesh-apiserver-server-cert \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
done
```

```
issuer=CN=clustermesh-root-ca
issuer=CN=clustermesh-root-ca
```

**Demo 24 (2026-09-12) amends step 5:** the same upgrade must also carry `hubble.tls.auto.method=certmanager`
with the same `certManagerIssuerRef` — otherwise Hubble stays on per-cluster `cilium-ca` and the relay
cannot reach the other cluster's nodes (gotcha #71). The complete per-cluster values, mesh and Hubble
together, are `demos/24-clustermesh-enterprise/{clusters,poc1,poc2}.yaml`.

Now continue to Step 9.4. **Skip 9.3b entirely** — the routes are alternatives, not steps.

### Step 9.3b — ROUTE B: copy Cilium's self-signed CA (quick start)

**Do this before `clustermesh connect`, or you will hit gotcha #20.** Each cluster generates its
own Cilium CA at install, and the mesh refuses mismatched CAs.

The clean way is to pass the same `tls.ca.cert`/`tls.ca.key` to **both** `helm install` commands.
If you did not (as here), copy the CA while the second cluster is still empty:

```bash
kubectl --context kind-poc1 -n kube-system get secret cilium-ca -o yaml \
  | grep -v '^\s*\(resourceVersion\|uid\|creationTimestamp\|selfLink\)' \
  | kubectl --context kind-poc2 -n kube-system apply -f -
```

Then delete the certs issued under the old CA and **regenerate them** — note that neither a pod
restart nor `helm upgrade` will do it (gotcha #21):

```bash
kubectl --context kind-poc2 -n kube-system delete secret \
  clustermesh-apiserver-{admin,server,remote,local}-cert
```

```bash
kubectl --context kind-poc2 -n kube-system create job clustermesh-certgen-manual \
  --from=cronjob/clustermesh-apiserver-generate-certs
```

Confirm the new cert carries the **shared** CA — the dates must match poc1's exactly:

```bash
kubectl --context kind-poc2 -n kube-system get secret clustermesh-apiserver-server-cert \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -dates
```

```
notBefore=Sep 10 20:21:40 2026 GMT
notAfter=Sep  9 20:21:40 2029 GMT
```

### Step 9.4 — enable and connect

```bash
cilium clustermesh enable --context kind-poc1 --service-type NodePort
cilium clustermesh enable --context kind-poc2 --service-type NodePort
```

`NodePort` because kind has no cloud load balancer for the mesh API server. The CLI warns it "may
fail when nodes are removed" — heed that in production, ignore it on a laptop.

```bash
cilium clustermesh connect --context kind-poc1 --destination-context kind-poc2
```

```
✅ Connected cluster kind-poc1 <=> kind-poc2!
```

### Step 9.5 — verify (connecting ≠ connected)

```bash
cilium clustermesh status --context kind-poc1 --wait
```

```
✅ All 5 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
✅ All 1 KVStoreMesh replicas are connected to all clusters [min:1 / avg:1.0 / max:1]

🔌 Cluster Connections:
  - poc2: 5/5 configured, 5/5 connected - KVStoreMesh: 1/1 configured, 1/1 connected
```

Run it on **both** sides. `--wait` matters: the first attempts legitimately report
`3 nodes are not ready` while the mesh converges, and it settles within about a minute.

Demo 07 then deploys the global service. → [demos/07-clustermesh/README.md](../demos/07-clustermesh/README.md)

---
> **Then put an application on the mesh:** demo 15 (`demos/15-bank/`) is a five-component bank split
> (walk-through with every manifest and command, each with its reason: `demos/15-bank/GUIDE.md`)
> across poc1 and poc2 over global Services, with active-active and zero-loss failover measured by
> `demos/15-bank/check.sh`. It is the demo to show a product team.

## Step 10 — flow export and tracing (demo 10)

Optional. Adds a persistent, queryable record of every flow, shipped to an OpenTelemetry Collector.

**Read the reframing first.** "Tracing" here is **flow export as OTLP logs**, not application spans:
`hubble-otel` is archived and Cilium 1.20 emits no spans (gotcha #30). What you get is every flow,
per node, persisted and correlatable — which also removes demo 01's ring-buffer limit.

```bash
# 1. enable dynamic export (three files: all flows, drops only, L7 only)
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 \
  --reuse-values -f cilium/values-hubble-export.yaml
kubectl -n kube-system rollout restart daemonset/cilium       # first enable only
```

```bash
# 2. confirm the files exist ON THE NODE (a hostPath) -- one set per node
docker exec poc1-worker ls -l /var/run/cilium/hubble/
```

```bash
# 3. the collector, one per node, must run as root for its hostPath checkpoint (gotcha #31)
kubectl apply -f demos/10-tracing/otel-collector.yaml
kubectl -n otel get pods            # 5/5 Running
```

```bash
# 4. see a flow arrive as an OTLP record
kubectl -n otel logs -l app=otel-collector --since=2m | grep -A6 'LogRecord #' | head -20
```

**Changing the export set later needs no restart** — edit the overlay and `helm upgrade` — but allow
**about a minute** for the mounted ConfigMap to propagate before concluding it did not work.

→ [demos/10-tracing/README.md](../demos/10-tracing/README.md)

---

## Step 11 — a third cluster on its own docker network, and pausing clusters (demo 11)

The forensic comparison needs a control cluster the VM cannot hold alongside poc1 and poc2. Two
things make that workable, both scripted and both measured:

```bash
# poc3 on its OWN docker network, so it can never take an address poc1/poc2 need (NETWORKING_DESIGN §2b)
docker network create --subnet 172.30.0.0/16 --gateway 172.30.0.1 kind-classic
KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-classic kind create cluster --config clusters/poc3.yaml

# pause / resume without losing a multi-node cluster (gotcha #6): addresses are recorded, then PINNED on resume (gotcha #43)
scripts/cluster-pause.sh poc1 poc2
scripts/cluster-resume.sh poc1 poc2
```

Everything else — the rig, the five measurements, the tuning steps and the restore — is
`demos/11-kube-proxy-vs-cilium/README.md`.

## Step 12 — the security decisions, measured (demos 13 and 14)

Two questions a production review will ask, answered with runs rather than opinions:

- **"Is mTLS on, and should it be?"** — Cilium's own "mutual authentication" is deprecated in 1.20
  and removed in 1.21; its successor, **ztunnel**, was run on a throwaway cluster (`clusters/poc4.yaml`,
  `cilium/values-poc4-ztunnel.yaml`) because it cannot start on any cluster with a `cluster.id`
  (gotcha #45). It is real mTLS on the wire and it breaks L4 and L7 network policy for enrolled
  traffic (measured), at −73 % throughput. **Decision: not the standard; identity policy + WireGuard
  (demo 04) is.** → `demos/13-ztunnel/README.md`, `docs/summary/MTLS_EVALUATION.md`.
- **"Have you tuned for connection rate?"** — a popular tuning post's knobs tested one by one; none
  applied here, and the one datapath knob is forced off by Gateway API (gotcha #49). The binding
  constraint is Hubble's per-flow CPU (demo 11). → `demos/14-tcp-crr-tuning/README.md`,
  `docs/TUNING.md` §5.

Both exercises restored poc1 from a `helm get values` snapshot and re-ran `scripts/check-routes.sh`
and `cilium clustermesh status` before being called done — the pattern to copy for any experiment
on a cluster you intend to keep (gotcha #46: never use the `cilium clustermesh` CLI for that).

## Step 13 — the database survives its cluster (demo 15, Part 8)

Demo 15 ends with the requirement a bank actually has: a database failure in one cluster must not
take the application down. The mechanism is PostgreSQL's own streaming replication, run **across
the mesh**: the poc2 primary keeps a replication slot, a Postgres hot standby in poc1 base-backs-up
from it through the global `postgres-primary` Service and replays its WAL continuously, `accounts`
falls back to the standby for reads, and promotion is one `pg_promote()` plus one env change.

```bash
kubectl --context kind-poc2 apply -f demos/15-bank/10-poc2.yaml               # primary: replicator role, slot, pg_hba (initdb script)
kubectl --context kind-poc1 apply -f demos/15-bank/40-postgres-standby-poc1.yaml   # the standby: pg_basebackup -R --slot, then a stock postgres
scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/dbfailover.sh  # the four test cases
FROM=3 demos/15-bank/dbfailover.sh                                              # only promotion + failback
```

| Event | What you do | What the app sees (measured) |
|---|---|---|
| primary pod restarts | nothing — StatefulSet + slot | reads 0 failed (served by the standby), writes pause 4 s |
| primary cluster's database lost | `SELECT pg_promote()` on the standby; `kubectl set env deploy/accounts PG_DSN=<standby>` | reads never stop; writes resume after promotion + one rollout — 20/20 |
| failback | `pg_dump` → rebuild the old side as standby → verify streaming → promote → verify a write → rebuild the other side | two short write pauses; balances identical afterwards |

Read the three gotchas before running it on anything that matters: a readiness probe must never
encode a role (#54), a failback must verify before it deletes (#55 — the first run here lost the
demo ledger), and a draining pod must fail readiness first (#56). The write-up, with every run
kept: `demos/15-bank/README.md` Part 8.

## Step 14 — Prometheus + Grafana, then Hubble on dashboards (demo 16)

Two sections, in this order — the Cilium chart refuses ServiceMonitors until the Operator's CRDs
exist (gotcha #57):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update prometheus-community
helm install monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --create-namespace \
  --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml --wait --timeout 10m   # Section A
kubectl --context kind-poc1 apply -f demos/16-monitoring/10-gateway.yaml                                    # https://grafana.poc.local
sudo sh -c 'demos/16-monitoring/hosts-entries.sh >> /etc/hosts'                                              # you run this
helm get values cilium -n kube-system --kube-context kind-poc1 -o yaml > .tmp/poc1-values-before-demo16.yaml
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 \
  --reuse-values -f demos/16-monitoring/values-cilium-metrics.yaml                                           # Section B (agents roll once; includes the docs' clustermesh.apiserver.metrics.* values)
kubectl --context kind-poc1 apply -f demos/16-monitoring/20-visibility-policies.yaml                        # DNS + HTTP on the proxy for bank
```

Every command, its reason and its recorded output: `demos/16-monitoring/README.md`.

## Step 15 — OBI: zero-code traces and RED metrics for the bank, both clusters (demo 18)

```bash
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml                      # now also an OTLP receiver + traces pipeline
kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector
kubectl --context kind-poc1 apply -f demos/18-obi/20-collector-service.yaml                    # the collector as a GLOBAL Service …
kubectl --context kind-poc2 apply -f demos/18-obi/20-collector-service.yaml                    # … the same object in the other cluster
demos/18-obi/deploy.sh poc1 ; demos/18-obi/deploy.sh poc2                                       # OBI v0.13.0, bank deployments only
sleep 45 ; demos/15-bank/exercise.sh 10 ; sleep 20                                              # gotcha #61: first spans +40 s, export +10–20 s
demos/18-obi/check.sh 3m                                                                        # the page's check, both clusters
kubectl --context kind-poc1 -n otel logs ds/otel-collector --since=3m | demos/18-obi/tracetree.py   # one payment as a tree
```

Cilium is not touched: with tcx on both sides the page's `bpf.tc.priority` does not apply (and is
not a 1.20.1 chart value). Recorded output and reasoning: `demos/18-obi/README.md`.

## Step 16 — the zero-trust cell for the bank, both clusters (demo 19)

```bash
demos/19-zero-trust-cell/render.py < demos/19-zero-trust-cell/intent.yaml > demos/19-zero-trust-cell/rendered/cell-policies.yaml
kubectl --context kind-poc1 delete -f demos/16-monitoring/20-visibility-policies.yaml --ignore-not-found   # allow-all; superseded
for c in poc1 poc2; do
  kubectl --context kind-$c apply -f demos/19-zero-trust-cell/10-platform-baseline.yaml    # the clusterwide boundary
  kubectl --context kind-$c apply -f demos/19-zero-trust-cell/rendered/cell-policies.yaml   # the rendered per-component policies
done
kubectl --context kind-poc1 apply -f demos/19-zero-trust-cell/20-rbac.yaml                  # the developer role
demos/15-bank/exercise.sh 40 ; scripts/check-routes.sh ; demos/19-zero-trust-cell/drops.sh 5m
demos/19-zero-trust-cell/egress-test.sh poc1                                                 # the boundary, from a debug pod
```

External names need Part 0 first (CoreDNS forward to public resolvers, gotcha #63). Every command
with its reason and recorded output: `demos/19-zero-trust-cell/README.md`.

## Step 17 — Spring Boot microservices in `springboot` (demo 20)

```bash
demos/20-springboot/scale.sh down                                              # room for six JVMs (bank + routes Deployments → 0)
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml && kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector   # + zipkin receiver
kubectl --context kind-poc1 apply -f demos/18-obi/20-collector-service.yaml ; kubectl --context kind-poc2 apply -f demos/18-obi/20-collector-service.yaml   # + port 9411
kubectl --context kind-poc1 apply -f demos/20-springboot/10-petclinic.yaml    # six Deployments, one at a time through init containers (5–10 min cold)
kubectl --context kind-poc1 apply -f demos/20-springboot/20-gateway.yaml      # https://petclinic.poc.local
sudo sh -c 'demos/20-springboot/hosts-entries.sh >> /etc/hosts'               # you run this
sleep 90 ; demos/20-springboot/check.sh 5                                      # gotcha #65: Eureka needs ~90 s after any rollout
demos/20-springboot/javaagent.sh on                                            # the OpenTelemetry Java agent, one Deployment at a time
kubectl --context kind-poc1 apply -f demos/20-springboot/40-monitoring.yaml    # Micrometer → Prometheus, the Spring Boot dashboard in Grafana
demos/20-springboot/scale.sh up                                                # when done with the lab
```

Every command with its reason and recorded output: `demos/20-springboot/README.md`.

## Step 18 — the reference Hubble values and dashboard folders (demo 16 Section C), then Tempo (demo 21)

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 --reuse-values -f demos/16-monitoring/values-cilium-metrics.yaml   # +ignoreAAAA, dashboards → monitoring
kubectl --context kind-poc1 -n kube-system rollout restart ds/cilium                        # a context change: the dynamic reload refuses it (gotcha #59)
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
helm install tempo grafana/tempo --version 1.24.4 -n monitoring --kube-context kind-poc1 -f demos/21-tempo/values-tempo.yaml
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml   # folders, Tempo datasource, exemplar links
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml && kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector   # + otlp/tempo exporter
kubectl --context kind-poc1 apply -f demos/21-tempo/20-springboot-l7-visibility.yaml        # Hubble reads traceparent only on the proxy
# Service Graph + Traces Drilldown: the same two files with tempo.metricsGenerator.enabled, the processors
# [service-graphs, span-metrics, local-blocks] and prometheusSpec.enableRemoteWriteReceiver; the two helm upgrade
# lines above again (demo 21 Parts 5–6).
```

Proof and reasoning: `demos/16-monitoring/README.md` Section C, `demos/21-tempo/README.md`.

Seeing traces: Grafana → Explore → datasource *Tempo* → *Search* (service name) or *TraceQL*
(`{ resource.service.name="api-gateway" && duration > 100ms }`), or click an exemplar dot on the Hubble
L7 dashboard (`reporter=server`). Details and working links: `demos/21-tempo/README.md` Part 4.

## Step 19 — poc2 as a spoke of the observability hub (demo 22)

```bash
kubectl --context kind-poc1 -n springboot scale deploy --all --replicas=0 ; demos/20-springboot/scale.sh up      # memory
helm install edge prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --create-namespace \
  --kube-context kind-poc2 -f demos/22-multicluster-observability/values-prometheus-poc2.yaml --wait          # release `edge`, NOT `monitoring` (#69)
for c in poc1 poc2; do kubectl --context kind-$c apply -f demos/22-multicluster-observability/10-remote-write-service.yaml \
  -f demos/22-multicluster-observability/20-tempo-central-service.yaml; done                                 # the hub's role-named global Services
kubectl --context kind-poc2 apply -f demos/22-multicluster-observability/30-otel-collector-poc2.yaml           # a collector per cluster
demos/22-multicluster-observability/apply-poc2.sh                                                             # Cilium metrics on poc2, cluster=poc2
demos/15-bank/exercise.sh 20 ; sleep 60                                                                       # then any dashboard with cluster=poc2
```

```bash
# Part 4 (2026-09-12): the hub's OWN scrapes get cluster=poc1 through a default scrape class — the values file carries it now
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml
```

Proof and the standard: `demos/22-multicluster-observability/README.md`.

## Step 20 — the collector as a per-cluster gateway (demo 23)

```bash
for c in poc1 poc2; do kubectl --context kind-$c apply -f demos/23-collector-per-cluster/10-collector-service.yaml; done   # no global annotation (#70)
kubectl --context kind-poc2 apply -f demos/23-collector-per-cluster/20-otel-collector-poc2.yaml                           # 2 replicas, PDB, persistent queue
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml; kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector   # poc1's queue
demos/23-collector-per-cluster/check.sh                                                                                   # local backends only, queue metrics, Tempo per cluster
```

## Step 21 — the mesh declared, and Hubble on the enterprise CA (demo 24)

```bash
for c in poc1 poc2; do helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-$c --reuse-values \
  -f demos/24-clustermesh-enterprise/clusters.yaml -f demos/24-clustermesh-enterprise/$c.yaml; done   # replaces the clustermesh-apiserver pod once (#72): a window
demos/24-clustermesh-enterprise/check.sh                                                             # one root, every leaf, Hubble 7/7
```

## Step 22 — historical flows in Loki with hubble-observer (demo 25)

```bash
demos/25-hubble-observer-loki/chart-prep.sh                                                    # sources, versions, default values pulled — first, every time
helm install loki grafana/loki --version 7.3.0 -n monitoring --kube-context kind-poc1 -f demos/25-hubble-observer-loki/values-loki.yaml --wait
helm install hubble-observer demos/25-hubble-observer-loki/chart/hubble-observer -n hubble-observer --create-namespace \
  --kube-context kind-poc1 -f demos/25-hubble-observer-loki/values-hubble-observer.yaml --wait          # vendored from the operator's fork (PR #9 fix + docs): policy ON, cf2cnp on
# the deployment path now: demos/25-hubble-observer-loki/chart-from-fork.sh develop   # the fork's DEFAULT branch = every change of this demo, merged
kubectl --context kind-poc1 apply -f demos/25-hubble-observer-loki/20-cf2cnp-route.yaml                 # cf2cnp.poc.local through the demo 09 Gateway
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml; kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector   # observer stdout → Loki
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml   # the Loki data source
demos/25-hubble-observer-loki/dashboard-from-file.sh demos/25-hubble-observer-loki/chart/hubble-observer/dashboard/cilium-hubble-flows.json monitoring grafana-dashboard-hubble-observer hubble-observer-23862 Hubble | kubectl --context kind-poc1 apply -f -
sudo sh -c 'demos/25-hubble-observer-loki/hosts-entries.sh >> /etc/hosts'                               # cf2cnp.poc.local on the Mac
demos/25-hubble-observer-loki/check.sh
# Part 5 — the relays on mTLS (both clusters), the observer and the operators with their own certificates
kubectl --context kind-poc1 apply -f demos/25-hubble-observer-loki/30-relay-mtls-client-cert.yaml
for c in poc1 poc2; do helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-$c --reuse-values \
  -f demos/24-clustermesh-enterprise/clusters.yaml -f demos/24-clustermesh-enterprise/$c.yaml; done          # relay server TLS + mTLS (render first; no mesh change)
helm upgrade hubble-observer demos/25-hubble-observer-loki/chart/hubble-observer -n hubble-observer --kube-context kind-poc1 -f demos/25-hubble-observer-loki/values-hubble-observer.yaml
for c in poc1 poc2; do kubectl --context kind-$c apply -f demos/25-hubble-observer-loki/40-hubble-cli-client-cert.yaml; done
hubble status -P --kube-context kind-poc1 $(scripts/hubble-tls.sh kind-poc1)                                # every hubble command from here on
```
