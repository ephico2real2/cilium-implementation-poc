# Demo 14 — the "fix TCP_CRR on Cilium" blog, tested here

## Summary context

The operator found a post — [Fix Connection Rate (TCP_CRR) Cilium Performance](https://oneuptime.com/blog/post/2026-03-14-fix-connection-rate-tcp-crr-cilium-performance/view)
— listing configuration changes to raise Cilium's new-connection rate: bigger BPF conntrack/NAT
maps, shorter CT timeouts, socket-level load balancing for pods, kernel sysctls, simpler policies.
Demo 11 had already measured connection churn on this rig and found its bottleneck (Hubble's
per-flow CPU, gotcha #41). This demo tests the post's items one at a time on poc1 **with the
current facts read first** — most tuning advice is right somewhere and wrong here, and only the
numbers say which. Everything is in `output/transcript.txt`; poc1 was restored from a values
snapshot afterwards (Socket LB coverage back to `Hostns-only`, `check-routes.sh` 0 failures,
ClusterMesh 5/5).

## The items, the facts, the result

| Blog item | What this cluster actually has (read, not assumed) | Tested? | Result |
|---|---|---|---|
| `bpf.ctTcpMax=1048576`, `bpf.ctAnyMax=524288`, `bpf.natMax=1048576` — "reduce hash collisions" | Dynamic sizing (`ratio 0.0025` of 16 GiB): **CT TCP 147,099**, CT any 73,549, NAT 147,099 entries (read from the pinned maps with `bpftool`). The 64-connection churn left **17,138** CT entries — **12 %** of the map. | no — not binding | A map at 12 % has no collision problem to fix; 1 M entries would cost memory for nothing here. Size maps from *measured* occupancy under your peak, not from a blog. |
| `bpf-ct-timeout-regular-tcp=1h`, `…-tcp-syn=30s`, `…-any=30s` — "free entries faster" | In force: TCP **2h13m20s**, SYN 1m, FIN 10s, any 1m (agent flags). | no — same reason | Timeouts govern occupancy, and occupancy is 12 %. Shortening them trades memory you are not short of for early eviction of long-lived idle flows. |
| `socketLB.enabled=true`, `socketLB.hostNamespaceOnly=false` — "NAT at connect() instead of per packet" | `Socket LB: Enabled`, **`Coverage: Hostns-only`** — pods are not covered. | **yes** | **No effect — and it cannot have one here.** After the upgrade and a full agent rollout the coverage line was still `Hostns-only`. The chart renders `bpf-lb-sock-hostns-only: "true"` **unconditionally when `gatewayAPI.enabled`** (template comment: so per-backend weights on TCPRoute/UDPRoute take effect), which this cluster has for demos 05/09. Gotcha #49. Churn: 1,249 → 896 qps on the ClusterIP — within the noise of a VM at load 19–24, not a signal. |
| Kernel sysctls — `ip_local_port_range 1024 65535`, `tcp_tw_reuse 1`, `tcp_fin_timeout 10`, `tcp_max_syn_backlog 65535`, `somaxconn 65535` | Inside the fortio pod's netns: `32768 60999`, `tw_reuse 2` (kernel default: loopback only), `fin_timeout 60`, `somaxconn 4096`, `syn_backlog 1024`. `net.ipv4.*` are per-netns, so they were set in the **load generator's** namespace with `nsenter`. | **yes** | No improvement (1,032–1,211 qps, VM load spiked to 54 during the run). These are client-side hygiene for a load generator running out of ephemeral ports — 64 connections at ~1,200/s recycle ~28,000 ports per 8 s run inside a 28,231-port range, so it was close to mattering, and would matter at kube-proxy-class rates (8,926 qps in demo 11). Not a Cilium tuning. |
| `tcp_fastopen=3`, `fs.file-max` | not tested | — | TFO needs application support on both ends; `file-max` was not a limit (no EMFILE anywhere). |
| "Use CIDR-based L3 policies instead of FQDN" | no FQDN policies in this PoC | n/a | Sound advice (FQDN policy puts a DNS proxy in the path); nothing here to measure it on. |

## What the numbers say

```
baseline                         pod-ip 1,257  clusterip 1,249  dns 1,057 qps   agent 100–120 %
socket LB for pods (no effect)   pod-ip 1,246  clusterip   896  dns   716 qps   agent  75–182 %
+ load-generator sysctls         pod-ip 1,032  clusterip 1,211  dns 1,032 qps   agent 109–200 %   (VM load 54)
```

Every row is the same ~1.0–1.3 k qps with `cilium-agent` pegged at a CPU — the demo 11 signature.
**On this rig the connection rate is bound by Hubble's per-flow processing, and none of the blog's
knobs touch that.** With Hubble off, the same load did 8.9–9.5 k qps (demo 11, Part 3). The post
is not wrong; its knobs address a different bottleneck — maps or ports at the ceiling — that this
cluster is nowhere near, and its one datapath knob is disabled by a feature we run.

## What to take away

| Claim | Evidence |
|---|---|
| Read the map occupancy before sizing maps | 17,138 of 147,099 CT entries (12 %) at peak churn |
| The chart forces socket LB to host-namespace-only with Gateway API on | template: `bpf-lb-sock-hostns-only: "true"` under `if .Values.gatewayAPI.enabled`; coverage unchanged after rollout |
| Client sysctls are load-generator hygiene, not Cilium tuning | per-netns; no change at 1.2 k qps; ~28 k port recycles per run in a 28 k range |
| This rig's CRR ceiling is Hubble, not conntrack | agent at 100–200 % in every row; 7× higher with Hubble off (demo 11) |

## Reproduce

```bash
helm get values cilium -n kube-system --kube-context kind-poc1 > .tmp/snapshot.yaml   # restore target
scripts/churn-decompose.sh poc1 baseline
helm upgrade cilium cilium/cilium -n kube-system --kube-context kind-poc1 --version 1.20.1 --reuse-values --set socketLB.hostNamespaceOnly=false
kubectl --context kind-poc1 -n kube-system rollout restart ds/cilium     # gotcha #42: 2–3 min Gateway outage
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep 'Socket LB Coverage'   # still Hostns-only
scripts/churn-decompose.sh poc1 "socket LB for pods"
helm upgrade cilium cilium/cilium -n kube-system --kube-context kind-poc1 --version 1.20.1 -f .tmp/snapshot.yaml && kubectl --context kind-poc1 -n kube-system rollout restart ds/cilium
```

## Evidence

**Captures not taken yet** — the tuning runs need a quiet VM (they measure TCP_CRR under load); the numbers are in the transcript. Captures to add: netperf output before/after each sysctl on a VM with headroom. See [`output/screenshots/MISSING-CAPTURE.md`](output/screenshots/MISSING-CAPTURE.md) and [`/missing-captures.md`](../../missing-captures.md).

