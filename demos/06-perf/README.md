# Demo 06 — Performance, and the honest limits of measuring it here

## Summary context

**What this demo is for.** Cilium's performance story is real — eBPF service load balancing scales
where iptables rule chains do not, and features like netkit, BIG TCP and the bandwidth manager
reduce per-packet cost. This demo measures what *can* be measured on a laptop, and is explicit
about what cannot.

**Read this first: a five-node kind cluster inside a Docker Desktop VM is not a performance lab.**
All traffic is loopback inside one VM on one machine; there is no physical NIC, no real link, and
no other tenant. The numbers below are useful for *detecting a large regression* and for *seeing
the shape* of a cost. They are not vendor benchmarks and must not be quoted as throughput figures
for Cilium.

Three of the features this demo was meant to showcase **cannot run on this kernel at all** — and
finding out exactly why is more useful than a synthetic number would have been.

All output is in [`output/transcript.txt`](output/transcript.txt).

---

## Part 1 — the test rig

`demos/06-perf/iperf3.yaml` pins a server and a client to **different** nodes with `nodeName`:

```bash
kubectl apply -f demos/06-perf/iperf3.yaml
kubectl -n perf get pods -o wide
```

```
iperf3-client 10.10.3.103 poc1-worker2
iperf3-server 10.10.4.116 poc1-worker
```

Two design decisions, both to keep the variable count at one:

- **Its own namespace.** The `default` namespace carries demo 02's default-deny policy. Benchmarking
  there would measure policy denial, not throughput.
- **Pinned to different nodes.** If the scheduler put both pods on one node the traffic would never
  reach the network — a loopback `memcpy`, and a meaningless number.

```bash
kubectl -n perf exec iperf3-client -- iperf3 -c 10.10.4.116 -t 10 -f m
```

## Part 2 — baseline throughput, and why you need more than one run

Five consecutive 10-second runs, encryption off:

| Run | Throughput |
|---|---|
| 1 | 9240 Mbits/sec |
| 2 | 9962 Mbits/sec |
| 3 | **7656 Mbits/sec** |
| 4 | 9876 Mbits/sec |
| 5 | **7551 Mbits/sec** |

**Median ≈ 9.2 Gbit/s, range 7.55–9.96 Gbit/s — a 25% spread across identical runs.**

That spread is the most important result on this page. Any comparison claiming a difference
smaller than ~25% on this rig is measuring noise. A single run proves nothing.

**A methodology trap, learned here.** An earlier sample recorded 7659 Mbits/sec against 9705 in the
same pair, and the cause was measuring **immediately after a `rollout restart`**. The agents were
still reprogramming. The runs above include a 45-second settle, and the guide now does too — if
you benchmark straight after a config change you are timing the reconfiguration.

## Part 3 — the cost of WireGuard encryption

Demo 04 promised this measurement rather than hand-waving it.

| Configuration | Throughput |
|---|---|
| WireGuard **enabled** | 4439 Mbits/sec |
| WireGuard **disabled** (median of 10 runs) | ≈ 9400 Mbits/sec |

**Encryption roughly halves throughput here — on the order of a 50% reduction.**

**Be careful with that number.** It is **one** WireGuard sample against a baseline that itself
varies by 25%, so treat it as *"the cost is large and clearly visible"*, not as "WireGuard costs
52.8%". To produce a defensible figure you would run ≥10 samples in each configuration, on real
hardware with a real NIC, and report medians with the spread. The honest conclusion from this rig
is directional: **encryption is not free, and the cost is big enough to plan capacity around.**

It is also the expected shape. ChaCha20-Poly1305 is fast but runs per packet, and this VM has no
crypto offload of any kind.

## Part 4 — three features this kernel cannot run (and how to tell)

This is where the demo earned its keep. Each was attempted, and each failed for a *specific,
diagnosable* reason rather than silently doing nothing.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status \
  | grep -iE 'BandwidthManager|BIG TCP|Device Mode'
```

```
IPv4 BIG TCP:            Disabled
IPv6 BIG TCP:            Disabled
BandwidthManager:        Disabled
Device Mode:             veth
```

### netkit — needs kernel ≥ 6.7

```bash
docker exec poc1-worker uname -r
```

```
6.6.12-linuxkit
```

netkit replaces the `veth` pair with a lower-overhead device and is one of Cilium's larger recent
wins. `Device Mode: veth` above confirms it is not in use. The Docker Desktop VM kernel is 6.6.12;
netkit needs 6.7. **Nothing can be done about this short of a different VM kernel.**

### Bandwidth manager (and BBR) — the kernel does not expose the sysctl

Enabling it looks like it works — the option reaches the agent:

```
level=info msg="  --enable-bandwidth-manager='true'"
level=info msg="  --enable-bbr='true'"
```

…and then the agent disables it, saying exactly why:

```
level=warn msg="BPF bandwidth manager could not read procfs. Disabling the feature."
  error="could not open the sysctl file /host/proc/sys/net/core/default_qdisc:
         open /host/proc/sys/net/core/default_qdisc: no such file or directory"
```

Confirmed directly:

```bash
docker exec poc1-worker sh -c 'cat /proc/sys/net/core/default_qdisc 2>&1 || echo ABSENT'
```

```
cat: /proc/sys/net/core/default_qdisc: No such file or directory
ABSENT
```

```bash
docker exec poc1-worker sh -c 'ls /proc/sys/net/core/'
```

```
rps_default_mask
somaxconn
txrehash
xfrm_acq_expires
xfrm_aevent_etime
xfrm_aevent_rseqth
xfrm_larval_drop
```

**Seven entries.** A normal Linux host has dozens. This is a heavily stripped linuxkit kernel and
the bandwidth manager needs a qdisc knob that simply is not there.

**BBR is impossible here for a second, independent reason** — it is not even compiled in:

```bash
docker exec poc1-worker sh -c 'cat /proc/sys/net/ipv4/tcp_available_congestion_control'
```

```
reno cubic
```

No `bbr` in the list. Setting `bandwidthManager.bbr=true` could never have worked.

**Credit where due:** Cilium detected both and **disabled the feature with a clear warning** rather
than half-enabling it or crashing. The status line and the log agree. That is the behaviour you
want from infrastructure software, and it is why the diagnosis took minutes rather than a day.

### BIG TCP — reported Disabled

Left off. BIG TCP needs driver support for large GSO/GRO segments, which this virtual interface
does not offer, and with no real NIC the feature has nothing to optimise.

## What to take away

| Question | Answer from this rig |
|---|---|
| Cross-node pod-to-pod throughput | ≈ 9.2 Gbit/s median, 7.6–10.0 range |
| Is the measurement stable? | **No** — 25% spread; ignore differences below that |
| What does WireGuard cost? | Roughly half the throughput; large and clearly visible |
| netkit? | **Unavailable** — kernel 6.6.12 < 6.7 |
| Bandwidth manager / BBR? | **Unavailable** — `default_qdisc` sysctl absent; BBR not compiled in |
| Does Cilium fail safely when a feature is unsupported? | **Yes** — disables it and says why, in both status and logs |

**The transferable lesson is not a number.** It is that a performance feature can be enabled in
config, accepted by the agent, and still be inactive — and that the only reliable way to know is to
read the status output *and* the startup logs, then confirm the underlying kernel facility exists.
`--enable-bandwidth-manager='true'` in the log is not the same as `BandwidthManager: Enabled` in
the status.

**To do this properly** you need bare metal or a cloud VM with a real NIC, kernel ≥6.7 for netkit,
and ≥10 samples per configuration. Cilium publishes such benchmarks; this demo is not one.

## Clean up

```bash
kubectl delete -f demos/06-perf/iperf3.yaml
```
