# TUNING — what to set on day 1, and what this rig measured

Cilium's performance story is real, but **the chart defaults do not deliver it**. This guide is the
short list of what to set before the first workload lands, in the order of evidence — each item
was measured in this repo (demo 11), and the status line that proves it is on is given so it can
be checked rather than assumed. Cilium's own reference:
[Tuning Guide](https://docs.cilium.io/en/stable/operations/performance/tuning/),
[Masquerading](https://docs.cilium.io/en/stable/network/concepts/masquerading/),
[CNI Performance Benchmark](https://docs.cilium.io/en/stable/operations/performance/benchmark/).

## Rule 0 — set it at install time, not later

Every value below changes the agent's datapath and **requires an agent restart**. On this rig a
restart takes the Gateway off the air for 2–3 minutes while Envoy re-receives its listeners
(gotcha #42), and a change of routing mode briefly breaks cross-node pod traffic while node routes
converge. On a cluster that is already serving, each of these is a maintenance window. On day 1
it is free. That is why `cilium/values-poc1.yaml` and `values-poc2.yaml` carry the day-1 values,
and why SETUP Step 5 installs with them rather than adding them "when performance matters".

## 1. eBPF masquerading → eBPF host routing — DAY 1, adopted here

```yaml
# cilium/values-poc*.yaml
bpf:
  masquerade: true
```

**What it means.** Pod IPs are private; traffic leaving the pod network is SNAT'ed to the node IP.
The chart default does that SNAT with **iptables** rules in the host's nat table — and because the
SNAT lives in netfilter, Cilium cannot bypass the host stack: every packet leaving a pod goes
pod → eBPF → **host stack + iptables** → NIC. That state is reported as `Host Routing: Legacy`.

**What changes.** With `bpf.masquerade=true` the SNAT is an eBPF program on the node's device,
and — quoting the docs — *"by default, BPF masquerading also enables the BPF Host-Routing mode"*.
The path becomes pod → eBPF → NIC: *"packets no longer hit the netfilter tables in the host
namespace."* That is the shortcut the tuning guide advertises, and it is **off** until this value is
set.

**Measured (demo 11, same VM, tunnel mode, Hubble off in both runs):** iperf3 pod-to-pod
9,110 → 10,193 Mbit/s median from this value alone; 15,147 with native routing on top. Connection
churn did not change — that cost was Hubble's (item 3).

**Prove it is on** — the two lines to read, before and after:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E '^Routing|^Masquerading'
Routing:                 Network: Tunnel [vxlan]   Host: Legacy                        <- chart default
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]

Routing:                 Network: Tunnel [vxlan]   Host: BPF                           <- bpf.masquerade=true
Masquerading:            BPF   [eth0]   10.10.0.0/24  [IPv4: Enabled, IPv6: Disabled]
```

**Requirements and limits.** Kernel ≥ 5.10 for BPF host routing (this VM: 6.6); IPv4 masquerading
is GA, IPv6 is beta; masquerading happens only on devices running the eBPF program (`Devices:` in
`cilium status --verbose` — `eth0` here); `ipv4NativeRoutingCIDR` is the range that is *not*
masqueraded (Cilium derives the per-node pod CIDR in tunnel mode; set it explicitly with native
routing). Nothing in demos 01–10 depends on iptables SNAT — verified after the change: policies,
Gateway (`scripts/check-routes.sh` 0 failures), ClusterMesh 5/5 connected.

## 2. Native routing instead of VXLAN — measured, NOT adopted here (yet)

```yaml
routingMode: native
autoDirectNodeRoutes: true          # all nodes on one L2 segment: each node gets a route per peer pod CIDR
ipv4NativeRoutingCIDR: 10.10.0.0/16
```

**Measured:** 10,193 → 15,147 Mbit/s pod-to-pod (spread 19 %), churn 7,764 qps — within noise of
the kube-proxy control on a heavier cluster. Encapsulation is per-packet work that a single-L2
rack does not need; in production this is the normal shape (a route per node, or BGP — see
`docs/summary/BGP_FRR_PLAN.md`).

**Why not adopted:** ClusterMesh between poc1 and poc2 was established over VXLAN, and with native
routing the peer cluster's pod CIDR must be routable from every node — `autoDirectNodeRoutes` only
covers the local cluster. That path was not verified, and this repo does not adopt what it has not
measured. Adopt it on a single-cluster install, or verify the mesh first.

## 3. Hubble is a CPU budget line — size it, do not discover it under load

**Measured:** 64 parallel connections with `Connection: close` (≈10 k new connections/s per node):
1,197 qps with Hubble + flow export on, 8,929–9,450 qps with Hubble off; `cilium-agent` 120 % →
10 % CPU. The only symptom before measuring was one line in `hubble observe`:
`EVENTS LOST: OBSERVER_EVENTS_QUEUE CPU(0) 5983` (gotcha #41).

The agent is not in the packet path; it was starved by per-flow processing on a VM already
carrying three control planes. In production: give the agent CPU requests that reflect the
connection rate, export what you need (`drops`, `http`) rather than every flow (demo 10's dynamic
exporter does this per file), and treat `EVENTS LOST` as an alert, not a log line.

## 4. What this kernel cannot do (demo 06, Part 4)

| Feature | Needs | This VM (6.6.12-linuxkit) |
|---|---|---|
| netkit devices | kernel ≥ 6.8 (docs) | no — `Device Mode: veth` |
| Bandwidth manager + BBR | `net.core.default_qdisc` sysctl; BBR compiled | no — sysctl absent, BBR not compiled |
| BIG TCP | kernel ≥ 6.3 (IPv4) + BPF host routing + supported NIC | no — `IPv4 BIG TCP: Disabled` |

They enable in config and stay inactive (gotcha #17). Check the status lines, not the values.

## 5. The one-line checklist for a new cluster

```bash
helm install cilium cilium/cilium --version 1.20.1 -n kube-system -f cilium/values-poc1.yaml   # bpf.masquerade: true is in the file
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E '^KubeProxyReplacement|^Routing|^Masquerading'
```
```
KubeProxyReplacement:    True
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Masquerading:            BPF   [eth0]   …
```

If `Host:` says `Legacy`, the datapath bypass is off and every throughput number you take will be
the wrong number.
