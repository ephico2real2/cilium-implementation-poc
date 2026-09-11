# Demo 11 — kube-proxy (iptables) vs Cilium: the forensic comparison

## Summary context

Every earlier demo shows what Cilium *does*. None of them measured what it does **better**, because
there was nothing to measure it against. This demo builds that control — `poc3`, the same
Kubernetes v1.36.4 on the same Docker VM with the stock datapath (kindnet + kube-proxy in
iptables mode) — and runs one script, `scripts/forensic.sh`, on both clusters. Five
measurements, each allowed to conclude exactly one thing:

| # | Measurement | What it may conclude |
|---|---|---|
| 1 | **Rule count vs Services** | how much per-node datapath state one Service costs |
| 2 | **Programming latency** | ms from `kubectl create service` to the first successful connection |
| 3 | **Throughput** | iperf3 worker→worker2, pod IP and via the Service, median of 5 with spread |
| 4 | **Connection churn** | fortio, 64 parallel, `Connection: close`: qps and latency percentiles |
| 5 | **Conntrack + CPU** | what the node pays during (4) |

**The result is not the slide.** Cilium wins rule count and programming latency outright. On
throughput and connection churn the *default* Cilium install lost — badly — and the forensic work
was finding out why: three separate causes, each isolated by changing one thing and re-measuring
(Part 3). With them addressed, Cilium reaches parity with kube-proxy on a cluster carrying three
control planes and Envoy that the control does not. Every number below is in
`output/transcript.txt`, with the corrections kept in place where a step was mislabelled or failed.

## Part 1 — the rig, and why it is fair

`poc3` (clusters/poc3.yaml): 1 control-plane + 2 workers, `disableDefaultCNI: false`,
`kubeProxyMode: iptables` (both written out so the contrast with poc1 is visible), pod
`10.30.0.0/16`, service `10.31.0.0/16`, on **its own docker network** `kind-classic`
(`172.30.0.0/16`) — NETWORKING_DESIGN §2b explains why that matters for pausing clusters.

The measurement rig (`00-rig.yaml`) is applied unchanged to both clusters: three `web` backends
(the demo 09 image) on `<cluster>-worker`, an iperf3 server beside them, a `nicolaka/netshoot`
client and a `fortio` load generator on `<cluster>-worker2`, so every byte crosses the node-to-node
path as in demo 06. Memory was the constraint: 16 GiB VM, poc1+poc2 use ~11 GiB, so the clusters
were **paused and resumed** around the runs (`scripts/cluster-pause.sh` / `cluster-resume.sh`,
Part 5). The two clusters never ran their measurements at the same time.

**What is NOT equal, and is reported rather than hidden.** poc1 has three control planes (three
etcd, three API servers), Envoy on every node, ClusterMesh, Hubble, five OTel collectors and L2
announcement leases; at rest its nodes burn 41–73 % CPU each (≈2.8 cores) and the VM load sits at
13–18. poc3 at rest: 27 % / 4 % / 3 %. That is what a five-node observability-heavy cluster
costs, and it depresses every poc1 number below by an amount this rig cannot separate out.

## Part 2 — the five measurements, default install vs default install

Cilium as installed by SETUP (tunnel/VXLAN, iptables masquerade, Hubble + flow export + OTel on)
versus kube-proxy iptables. `scripts/forensic.sh poc3` then `scripts/forensic.sh poc1`.

### 1. Rule count vs Services — Cilium, decisively

1,000 generated ClusterIP Services, each selecting the same 3 backends:

| Services | kube-proxy: iptables rules (`KUBE-SVC` / `KUBE-SEP`) | Cilium: iptables rules | Cilium: eBPF LB map entries |
|---|---|---|---|
| 0 (rig only) | 78 (29 / 44) | 46 | 110 |
| 100 | 1,178 (629 / 1,244) | 48 | 610 |
| 500 | 5,578 (3,029 / 6,044) | 48 | 2,610 |
| 1,000 | **11,078** (6,029 / 12,044) | **48** | **5,110** |

kube-proxy adds ~11 iptables rules per Service (with 3 endpoints), evaluated **linearly** on every
new connection; the nat table alone reports 11,050 rules at 1,000 Services. Cilium's iptables stay
flat and each Service costs ~5 hash-map entries, looked up in O(1). kube-proxy's own metric
`kubeproxy_sync_proxy_rules_duration_seconds` summed 4.6 s over 75 syncs during the growth (≈61 ms
per sync at this size); the docs' guidance to raise `minSyncPeriod` when this exceeds 1 s is where
that curve goes.

### 2. Programming latency — Cilium, ~2× faster and flat

Per sample: a Service with a **pre-chosen ClusterIP** is created while a poller inside the client
pod is already connecting to it every 20 ms (bash `$EPOCHREALTIME`); the Mac↔VM clock skew is
measured (best of 7, 64–84 ms) and subtracted.

| Existing Services | kube-proxy (3 samples, ms) | Cilium (3 samples, ms) |
|---|---|---|
| 0 | 1,342 / 1,261 / 1,265 | 553 / 562 / 286 |
| 100 | 1,339 / 1,250 / 1,267 | 549 / 586 / 909 |
| 500 | 1,347 / 1,563 / 1,278 | 890 / 542 / 229 |
| 1,000 | **1,732 / 1,671 / 1,583** | 713 / 218 / 230 |

kube-proxy's floor is its `minSyncPeriod: 1s` (the config on poc3), plus rule-set size: +400 ms at
1,000 Services. Cilium is 0.2–0.9 s and does not trend with scale. Bulk creation showed the same
shape: the 1,000th Service was reachable 46 s after the apply began on poc3 (32 s of which was the
API accepting 500 objects), 50 s on poc1 — there the API side was slower (three control planes on
a loaded VM), the datapath side was 0.5 s.

### 3. Throughput — the default Cilium install LOST

| | pod IP, median (spread) | via Service, median (spread) |
|---|---|---|
| kube-proxy / kindnet | **16,825 Mbit/s** (7.4 %) | **16,741** (3.1 %) |
| Cilium, default install | 6,764 (35.9 %) | 7,468 (33.7 %) |

Half the throughput and four times the noise. Part 3 explains it.

### 4–5. Connection churn — the default Cilium install lost by 7×

fortio, 64 parallel connections, `Connection: close` (every request a new TCP connection), 20 s:

| | qps | p50 | p99 | conntrack on the backend node | node CPU (worker / worker2) | datapath daemon CPU |
|---|---|---|---|---|---|---|
| kube-proxy / kindnet | **8,926** | 6.9 ms | 15.3 ms | nf_conntrack **38,621** | 420 % / 685 % | kube-proxy 0 % (not in the packet path) |
| Cilium, default install | 1,197 | 45.1 ms | 197.7 ms | nf_conntrack 112; eBPF CT 12,791 | 495 % / 725 % | **cilium-agent 50–108 %** |

With persistent connections the gap is small (40,806 vs 28,933 qps) — so it is the *per-connection*
cost. Two facts in that table point at the cause: the agent, which is not in the packet path, is
burning a CPU; and the kernel conntrack table stays at ~110 on Cilium (its eBPF CT holds the
state instead — the 38 k kernel entries kube-proxy accumulates are real memory and real lookups).

## Part 3 — forensic: three causes, isolated one at a time

Each step changes **one** thing on poc1 and re-runs `scripts/churn-decompose.sh` (the same churn
against the pod IP, the ClusterIP and the DNS name, 8 s each) and the iperf3 bench.

### Cause 1 — Hubble's per-flow work (the churn penalty, entirely)

The one line that named it, from `hubble observe` during the churn:

```
EVENTS LOST: OBSERVER_EVENTS_QUEUE CPU(0) 5983 (first: 21:17:09.981, last: 21:17:10.978)
```

| poc1 state | churn qps (pod-ip / clusterip / dns) | p50 | cilium-agent CPU |
|---|---|---|---|
| default: Hubble + flow export + 5 OTel collectors | 1,197 (via Service, 20 s run) | 45 ms | 50–108 % |
| flow export off, collectors off, Hubble relay on | 1,579 / 1,769 / 1,491 | 28–38 ms | 10–20 % idle, ~120 % under load |
| **Hubble off entirely** (relay, UI, monitor) + BPF host routing | **8,929 / 9,450 / 6,566** | **6.0 / 5.0 / 9.2 ms** | **9–10 %** |

At ~10 k new connections per second per node, Hubble's per-flow processing consumed the CPU this
VM had left; the datapath itself was never the bottleneck. This is not an argument against Hubble —
it is a CPU budget line that must be sized (gotcha #41).

The first attempt to switch Hubble off did nothing: the chart refuses `hubble.enabled=false` while
relay is enabled, the failed upgrade created no release, and a block was measured under a wrong
label before `cilium status` was read back — the transcript keeps the correction (gotcha #40).

### Cause 2 — `Host Routing: Legacy`: the default install still traverses netfilter

`cilium status --verbose` on the SETUP install:

```
Routing:                Network: Tunnel [vxlan]   Host: Legacy
Masquerading:           IPTables [IPv4: Enabled, IPv6: Disabled]
```

**Legacy** means every packet still goes through the host stack and iptables (masquerade rules)
— the eBPF host-routing bypass the tuning guide describes was not on. One value turns it on:

```bash
helm upgrade cilium cilium/cilium -n kube-system --version 1.20.1 --reuse-values --set bpf.masquerade=true
kubectl -n kube-system rollout restart ds/cilium
```
```
Routing:                Network: Tunnel [vxlan]   Host: BPF
Masquerading:           BPF   [eth0]   10.10.0.0/24
```

iperf3 pod-IP median: 6,764 → 8,662 (export off) → **9,110** (BPF host routing) → **10,193** (+ Hubble
off, spread down to 8.5 %).

### Cause 3 — VXLAN: encapsulation on a single L2 segment

All nodes share one docker network, so native routing with auto direct node routes is exactly the
production shape for a rack:

```bash
helm upgrade … --reuse-values --set routingMode=native --set autoDirectNodeRoutes=true --set ipv4NativeRoutingCIDR=10.10.0.0/16
```
```
Routing:             Network: Native   Host: BPF
10.10.4.0/24 via 172.18.0.5 dev eth0 proto kernel        <- a pod CIDR route per peer node
```

(The first cross-node curl after the switch timed out while routes converged — recorded, gotcha #42.)

### The best-configuration suite: native routing + BPF host routing + Hubble off

| | kube-proxy / kindnet | Cilium, best config | Cilium, default (for scale) |
|---|---|---|---|
| iptables rules @1,000 Services | 11,078 | 40 | 48 |
| programming latency @1,000 (ms) | 1,732 / 1,671 / 1,583 | 861 / 856 / 470 | 713 / 218 / 230 |
| throughput pod IP (spread) | **16,825** (7.4 %) | 15,147 (19.3 %) | 6,764 (35.9 %) |
| throughput via Service | **16,741** (3.1 %) | 15,547 (15.7 %) | 7,468 |
| churn qps, p50 / p99 (20 s via Service) | **8,926**, 6.9 / 15.3 ms | 7,764, 7.8 / 18.2 ms | 1,197, 45 / 198 ms |
| churn decomposition pod-ip / clusterip / dns | 13,911 / 14,407 / 9,577 | 10,942 / 11,716 / 7,702 | — |
| keep-alive qps | 40,806 | 36,180 | 28,933 |
| kernel conntrack under churn | 38,621 | ~110 (eBPF CT 27,957) | ~112 |
| datapath daemon CPU under churn | 0 % (not in path) | 9–18 % | 50–164 % |
| VM load during the suite | ~7 | 9–14 | 15–18 |

Read with the spreads: throughput is within noise; churn is 13 % behind on a cluster paying
≈2.8 cores of control-plane and proxy tax the control does not pay. What is **not** within noise:
the rule count (277× fewer), the programming latency (~2×), the kernel conntrack table (350×
smaller — the state lives in eBPF maps sized by Cilium, not in `nf_conntrack_max`), and the
behaviour with scale (kube-proxy's latency grows with rules; Cilium's does not).

## Part 4 — what this does and does not prove

**Proves.** On one machine, same day, same Kubernetes: Cilium's Service datapath is O(1) where
iptables is O(n); its programming path is faster and scale-independent; it keeps connection state
out of the kernel conntrack table. And two operational facts nobody's slide mentions: the
*default* helm install runs with legacy host routing and VXLAN (measurably slower than kindnet on
this VM), and Hubble at high connection churn is a CPU cost that must be budgeted.

**Does not prove.** Absolute numbers — a 16-vCPU Docker Desktop VM with all nodes on loopback is
not a network lab (demo 06 said so first); the 3–5 node asymmetry and the VM load are confounds
reported, not removed; kube-proxy's nftables and ipvs modes were not measured; netkit/BIG TCP
cannot run on this kernel (demo 06 Part 4). To go further: same node count both sides, a Linux
host with real NICs, and Cilium's own netperf methodology
([CNI Performance Benchmark](https://docs.cilium.io/en/stable/operations/performance/benchmark/),
[Tuning Guide](https://docs.cilium.io/en/stable/operations/performance/tuning/)).

**poc1 was restored** to its documented state afterwards from a snapshot of the release values
(`helm get values` before tuning): tunnel/VXLAN, iptables masquerade, Hubble + export + collectors,
Gateway API + ALPN — verified by `cilium status`, the flow-export ConfigMap, five collectors
Running and `scripts/check-routes.sh` at 0 failures (after the 2–3 minutes an agent rollout
takes the Gateway off the air, gotcha #42). **Adopted afterwards, as a separate decision:** `bpf.masquerade: true` is now in
`cilium/values-poc1.yaml` and `values-poc2.yaml`, applied to both clusters (release 22 / 9), with
`Host: BPF` on both, `check-routes.sh` 0 failures and ClusterMesh 5/5 — the transcript's last
block. The rule and the reasoning are `docs/TUNING.md`; native routing stays measured-not-adopted.

## Part 5 — reproduce it

```bash
# 1. the control cluster on its own network (NETWORKING_DESIGN §2b)
docker network create --subnet 172.30.0.0/16 --gateway 172.30.0.1 kind-classic
KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-classic kind create cluster --config clusters/poc3.yaml
kind load docker-image routedemo:local --name poc3

# 2. make room: pause poc1 and poc2 (records each container's address; resume pins it back — Part 5b)
scripts/cluster-pause.sh poc1 poc2

# 3. the rig, then the suite (re-apply once if pods hit the ServiceAccount race, gotcha #39)
kubectl --context kind-poc3 apply -f demos/11-kube-proxy-vs-cilium/00-rig.yaml
kubectl --context kind-poc3 -n forensic wait --for=condition=Ready pod --all --timeout=300s
scripts/record.sh demos/11-kube-proxy-vs-cilium/output/transcript.txt scripts/forensic.sh poc3

# 4. swap, and the same on Cilium
scripts/cluster-pause.sh poc3 && scripts/cluster-resume.sh poc1
kubectl --context kind-poc1 apply -f demos/11-kube-proxy-vs-cilium/00-rig.yaml
scripts/forensic.sh poc1
scripts/churn-decompose.sh poc1 "label"        # the three-target churn, for each tuning step
```

### Part 5b — pausing kind clusters without losing them

A multi-node kind cluster dies if its nodes come back with different addresses (gotcha #6).
`scripts/cluster-pause.sh` records `<ip> <name>` per container to `.tmp/ipmap-<cluster>.txt` and
stops them; `scripts/cluster-resume.sh` **pins** each address with `docker network disconnect` +
`docker network connect --ip` on the stopped container, then starts it. Measured on poc2 (back on
`.9`/`.10`, Ready in 10 s) and poc1 (six containers). The first version started containers in
ascending recorded order instead of pinning, and it broke the moment a *lower* address had been
freed by something else — `hubble-ui-proxy` (`.8`) was stopped for memory, so `poc2-worker` came
back on `.8` (gotcha #43). The script stopped itself at the first wrong address, which is the
behaviour that saved the cluster.

## What to take away

| Claim | Evidence |
|---|---|
| Service datapath state is O(1) in Cilium, O(n) in iptables | 48 vs 11,078 rules at 1,000 Services; 5,110 map entries |
| Service programming is ~2× faster and scale-flat | 0.2–0.9 s vs 1.3–1.7 s, kube-proxy +400 ms at 1,000 |
| Connection state stays out of kernel conntrack | ~110 vs 38,621 entries under churn |
| The **default** Cilium install is slower than kindnet on this VM | 6.8 vs 16.8 Gbit/s; `Host Routing: Legacy` |
| `bpf.masquerade=true` turns on eBPF host routing | status line `Host: BPF`; 9.1 → 10.2 → 15.1 Gbit/s with native routing |
| Hubble at ~10 k conn/s/node is a CPU budget line | 1.2 k → 8.9 k qps with it off; `EVENTS LOST: OBSERVER_EVENTS_QUEUE` |
| A five-node observability cluster pays a tax the control does not | ≈2.8 cores at rest, VM load 15 vs 7 |
| Cilium best config ≈ kube-proxy on throughput and churn, on that heavier cluster | 15.1 vs 16.8 Gbit/s (spread 19 %); 7.8 k vs 8.9 k qps |

## Clean up

```bash
kubectl --context kind-poc1 delete ns forensic; kubectl --context kind-poc3 delete ns forensic
scripts/cluster-pause.sh poc3                       # or: kind delete cluster --name poc3 && docker network rm kind-classic
```
