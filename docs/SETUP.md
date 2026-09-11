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
   the number; identify the interface by its `vmenet` member instead. → Step 2.6
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

The route itself is added **after** the restart, in Step 2.6 — the `bridge101` interface and the
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

## Step 6 — verify the install

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
```

`KubeProxyReplacement: True` is the headline. Read it together with the `No resources found` from
Step 3: services are being load-balanced in eBPF, and there is no kube-proxy anywhere to be doing it
instead.

---

## Step 2.6 — route the docker network from macOS (after the restart)

**Only meaningful once Step 2.3b is on and Docker has restarted.**

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
| `172.18.0.0/16` | **DESTINATION** — the subnet to route | the `kind` docker network (2.6.1) |
| `192.168.64.2` | **GATEWAY** — who to send it to | the Docker VM's address (2.6.2) |

Read as a sentence: *"to reach anything in 172.18.0.0/16, hand the packet to 192.168.64.2."*

### Step 2.6.1 — get the DESTINATION: the docker network subnet

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

### Step 2.6.2 — get the GATEWAY: the Docker VM's address

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

### Step 2.6.3 — derive both automatically

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

### Step 2.6.4 — run it

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

### Step 2.6.5 — verify

```bash
netstat -rn -f inet | grep '^172.18'
```

```
172.18             192.168.64.2       UGSc            bridge100
```

Read the flags: `U` up, `G` gateway, `S` static, `c` clones. The `Netif` column confirms it is
going out of the bridge from 2.6.2.

Now prove it end to end — a LoadBalancer address **and** a raw node IP, both from macOS:

```bash
curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' http://172.18.255.200/
```

```
200 in 0.007111s
```

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://172.18.0.6:6443/version
```

```
200
```

Compare with Step 2.3b, where the same node request returned `000` and the routing table had no
`172.18` entry at all.

### Managing the route

```bash
sudo route -n delete -net 172.18.0.0/16          # remove it
netstat -rn -f inet | grep '^172'                # list what is routed
```

**It is not persistent.** It is lost on reboot, and must be re-added whenever the Docker VM
restarts or its address changes. Re-run 2.6.3 to re-derive — the VM address can move.

### Step 2.6b — the no-sudo alternative (and why you might keep both)

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

## Step 8 — LoadBalancer addresses without a cloud (and without MetalLB or kube-vip)

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
so `cilium/lb-ippool.yaml` takes a slice from the **top** (`172.18.255.200–250`). They can never
collide.

```bash
kubectl --context kind-poc1 apply -f cilium/lb-ippool.yaml
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

**From the macOS browser**, `http://172.18.255.200/` works only once Step 2.6's route is added.
Without it you will get a timeout — and that is a host routing problem, not a Cilium one. The two
tests above tell those apart: if the container test returns 200 and the browser does not, the
cluster is fine and the route is missing.

---
