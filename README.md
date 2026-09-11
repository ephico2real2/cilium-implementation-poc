# cilium-kind-poc

A reproducible, local proof-of-concept that demonstrates what **Cilium** and **Hubble** give you
over a stock CNI + kube-proxy Kubernetes cluster — built on [kind](https://kind.sigs.k8s.io/), on a
laptop, from nothing.

**Start with [NETWORKING_DESIGN.md](NETWORKING_DESIGN.md).** It is the addressing plan the whole PoC is
built on — one subnet (`172.18.0.0/16`, the Docker `kind` network standing in for the LAN), the nodes on
it, and the **two reserved service ranges** carved out of it for Cilium LB IPAM (`.255.200–239`) and
for Cilium Gateway API only (`.255.240–250`) — with the layer-by-layer ASCII diagram, the exact route
commands for a MacBook (Docker Desktop) and for a Linux server, and the checklist for the conversation
with the network team. `scripts/network-plan.sh` reprints the live plan.

Every command is then documented one at a time in **[docs/SETUP.md](docs/SETUP.md)**, written for someone
who has not done this before: what each command does, its real captured output, and how to tell it
worked. Where something went wrong during the build, the failure and the diagnosis are kept in the
guide rather than tidied away — the debugging is the useful part.

## What it builds

| Cluster | Nodes | Pod CIDR | Service CIDR | Cilium cluster id |
|---|---|---|---|---|
| `poc1` | 3 control-plane + 2 worker | `10.10.0.0/16` | `10.11.0.0/16` | 1 |
| `poc2` | 1 control-plane + 1 worker | `10.20.0.0/16` | `10.21.0.0/16` | 2 |

`poc1` is the main cluster — three control planes so etcd keeps a real majority and a control-plane
failure can actually be demonstrated. `poc2` exists to be the far side of the ClusterMesh demo, so
it is deliberately minimal. The CIDRs do not overlap because ClusterMesh requires it.

Both clusters run with **no kube-proxy** (`kubeProxyMode: none`) and **no default CNI**
(`disableDefaultCNI: true`) — Cilium is both.

## Versions this was built and verified against

| Component | Version |
|---|---|
| kind | 0.33.0 |
| Kubernetes (node image) | v1.36.4, pinned by digest |
| Cilium | 1.20.1 |
| cilium CLI | v0.20.0 |
| Hubble CLI | 1.19.4 |
| cert-manager | v1.21.1 (chart; GitHub had v1.21.2 the same day — see gotcha #26) |
| Gateway API CRDs | v1.6.1 standard, plus experimental `TCPRoute` |
| OpenTelemetry Collector | contrib 0.160.0 |

**The Kubernetes version is not the default and that is deliberate.** kind 0.33.0 defaults to
v1.37.0, but Cilium 1.20.1 is e2e-tested only on 1.33–1.36. Taking the default would put the PoC on
an untested combination.

## Demos

| # | Demo | What it proves |
|---|---|---|
| 01 | Hubble flows + UI | Per-flow, identity-aware visibility that iptables cannot produce |
| 02 | L7 HTTP policy | Allow `POST /v1/request-landing`, deny `PUT /v1/exhaust-port` between the *same* two pods — inexpressible in iptables |
| 03 | kube-proxy free | Services load-balanced in eBPF; no kube-proxy DaemonSet exists at all |
| 04 | WireGuard | Node-to-node encryption from one helm value |
| 05 | Gateway API | Cilium as the Gateway controller, address from Cilium's own LB IPAM |
| 06 | Performance | Bandwidth manager + BBR, BIG TCP, measured with iperf3 |
| 07 | ClusterMesh | A global Service backed by pods in a second cluster, with failover |
| 08 | Enterprise CA | cert-manager root in poc1 issuing every cluster's mesh certificates; trust before join |
| 09 | Wildcard TLS + 3 route types | cert-manager wildcard and exact certs on one Gateway; `HTTPRoute`, `GRPCRoute`, `TCPRoute` from one 14 MB image |
| 10 | Flow tracing -> OpenTelemetry | Hubble dynamic flow export per node, tailed by an OTel Collector into OTLP; every flow persistent and queryable. **Events, not spans** -- hubble-otel is archived, see gotcha #30 |

## Regenerating the evidence

Every README here quotes captured output, and quoted output goes stale. `scripts/verify.sh` re-runs
all of it in one pass so you can compare against your own cluster rather than trusting a snapshot
from someone else's laptop:

```bash
scripts/verify.sh                              # to the terminal
scripts/verify.sh > docs/VERIFICATION_RUN.md   # as a document
```

The committed result is **[docs/VERIFICATION_RUN.md](docs/VERIFICATION_RUN.md)** — 433 lines of
real console output covering versions, cluster state, full Cilium status, and all five working
demos.

Two notes on reading it. It is **read-only** apart from HTTP requests to the demo app. And it
**always exits 0**, deliberately: several checks are *supposed* to fail — a `curl` that times out
is exactly what an L3 policy denial looks like, and it is recorded as `[exit code: 28]` rather than
hidden. It is an evidence report, not a pass/fail gate; read the output.

## Every gotcha, in one place

**[docs/GOTCHAS.md](docs/GOTCHAS.md)** lists all 32 traps this build actually hit — not things that
*could* go wrong, but the ones that did, with the real error text and the real fix. Skim it before
you start; several cost an hour each.

They share a shape worth naming up front: **most of them reported success while not working.**
`brew` said "already installed"; every container came back `Up` while the cluster was dead; the API
server answered `curl -k` with 200 while Cilium could not reach it; `kubectl patch` succeeded and
was silently reverted; a policy fix "worked" and opened a hole; `--enable-bandwidth-manager='true'`
appeared in the log for a feature that was off.

The three most expensive are expanded below.

## Findings worth your attention

Three things this build learned the hard way. Each is documented in full where it belongs in
[docs/SETUP.md](docs/SETUP.md), and measured in [docs/FINDINGS.md](docs/FINDINGS.md); they are
surfaced here because each one costs time if you meet it cold.

### 1. The bridge is `bridge100`, not `bridge101`

macOS assigns the interface number, so the number printed in guides (including Docker's own
ecosystem tooling, which names `bridge101`) is **not portable**. Find yours and confirm it by its
`vmenet` member rather than copying a number:

```bash
ifconfig -l | tr ' ' '\n' | grep -E '^bridge'
ifconfig bridge100 | grep -E 'inet |member'
```

```
inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
	member: vmenet0 flags=10803<LEARNING,DISCOVER,PRIVATE,CSUM>
```

See NETWORKING_DESIGN.md §4 and SETUP.md Step 3.5.

### 2. An API-version trap: the two Cilium LB CRDs did not graduate together

`CiliumLoadBalancerIPPool` has moved to **`cilium.io/v2`** and warns if you use the old group:

```
Warning: cilium.io/v2alpha1 CiliumLoadBalancerIPPool is deprecated; use cilium.io/v2
```

but `CiliumL2AnnouncementPolicy` is **still `v2alpha1`-only** in Cilium 1.20.1. A single manifest
containing both therefore needs *two different* `apiVersion` values. Check rather than assume:

```bash
kubectl api-resources | grep -iE 'loadbalancerippool|l2announcement'
```

See NETWORKING_DESIGN.md §0 and §3, SETUP.md Step 8 and `cilium/lb-ippool.yaml`.

### 3. Finish ALL Docker Desktop settings BEFORE creating any cluster

**A multi-node kind cluster does not survive a Docker Desktop restart.** This build changed Docker
settings *after* creating the cluster and lost it.

Docker reassigns container IPs on start, in whatever order containers come up:

| Container | Before restart | After restart |
|---|---|---|
| `poc1-control-plane` | 172.18.0.3 | **172.18.0.7** |
| `poc1-control-plane2` | 172.18.0.4 | **172.18.0.2** |
| `poc1-control-plane3` | 172.18.0.6 | **172.18.0.5** |
| `poc1-external-load-balancer` | 172.18.0.7 | **172.18.0.6** |

All six containers came back up. The cluster was still dead, because etcd's peer URLs and the API
server's certificate SANs were written around the original addresses:

```
kube-apiserver ... Exited (attempt 5)
E run.go:72] "command failed" err="error creating storage factory: context deadline exceeded"
W grpc: addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2379" ...}
```

etcd could not form a quorum against moved peers, so the API server could not reach its datastore.
The cluster had to be deleted and rebuilt.

**The rule:** make every Docker Desktop change — memory, `kernelForUDP` — **before** creating a
cluster, and apply them in **one** restart. This is SETUP.md **Step 2.7**, a hard gate before
Step 3.

**A silver lining.** The same failure independently re-validated an earlier decision. Across three
creations of `poc1` the load balancer's IP was `.7`, then `.6`, then `.2` — while its DNS name,
`poc1-external-load-balancer`, never changed. That is a second, independent reason Cilium is given
the **name** and not the address for `k8sServiceHost`: had the IP been baked into
`cilium/values-poc1.yaml`, every rebuild would have broken it.

## Status

Build in progress. See `docs/SETUP.md` for what is verified so far and `docs/FINDINGS.md` for
measured results.
