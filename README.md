# cilium-kind-poc

A reproducible, local proof-of-concept that demonstrates what **Cilium** and **Hubble** give you
over a stock CNI + kube-proxy Kubernetes cluster — built on [kind](https://kind.sigs.k8s.io/), on a
laptop, from nothing.

## What this is, technically

A **two-cluster Cilium 1.20.1 lab on kind**, built so every claim about Cilium is *measured* here
rather than quoted from a slide. Both clusters run with **no kube-proxy and no other CNI** — Cilium
is the only datapath — and the lab exercises, in order:

| Capability | Mechanism under test | Where proven |
|---|---|---|
| eBPF datapath, identity-aware | every pod gets a security identity; policy and load balancing are eBPF programs, not iptables chains | demos 01, 03 |
| L3–L7 network policy | `CiliumNetworkPolicy` with HTTP method+path rules enforced by a per-node Envoy | demo 02 |
| Service load balancing without kube-proxy | `kubeProxyReplacement: true`; the eBPF service map replaces the NAT chains | demo 03 |
| LoadBalancer addresses with no cloud | Cilium **LB IPAM** pools carved from the docker subnet + **L2 announcements** (no MetalLB, no kube-vip) | NETWORKING_DESIGN, SETUP 8 |
| Ingress via Gateway API | Cilium as `GatewayClass` controller; `HTTPRoute`, `GRPCRoute`, `TCPRoute`; TLS by SNI | demos 05, 09 |
| Enterprise PKI | cert-manager root CA in poc1, `ClusterIssuer` in both clusters, issuing mesh certs and Gateway wildcard/exact certs | demos 08, 09 |
| Multi-cluster | **ClusterMesh** over a shared root of trust; global Services with cross-cluster failover; a real multi-component app split across both clusters, active-active, zero-loss failover; **a database replicated into the other cluster through the mesh**, promotion and failback tested | demos 07, 08, 15 |
| Node-to-node encryption | WireGuard in the kernel, enabled/verified on the wire, then deliberately left **off** | demo 04 |
| Observability and export | Hubble flows with identities and verdicts; dynamic flow export per node → OpenTelemetry Collector (events, not spans) | demos 01, 10 |
| Measured against the stock datapath | the same five measurements on a kindnet + kube-proxy control cluster; the tuning that gets Cilium from half of kube-proxy's throughput to parity, and what Hubble costs at 10 k conn/s | demo 11 |

The network underneath is deliberately a *model of a real one*: the docker bridge is the LAN, kind
nodes are servers on it, reserved ranges at the top of the subnet are the VIP blocks, and the
laptop is a router with one static route in — so the same design can be handed to a network team
unchanged, with BGP substituted for L2 in production.

## How to use this as a tutorial — the path

1. **[NETWORKING_DESIGN.md](NETWORKING_DESIGN.md)** — the addressing plan and the ASCII diagram.
   Read it first; every address later comes from here. `scripts/network-plan.sh` reprints it live.
2. **[docs/SETUP.md](docs/SETUP.md)** Steps 0–8 — toolchain, Docker VM sizing (**all settings
   before any cluster**, Step 2.7), poc1, the host route, Cilium, LB IPAM. Stop at each *Check*.
   Read **[docs/TUNING.md](docs/TUNING.md)** with Step 5: the day-1 datapath values (eBPF
   masquerading → eBPF host routing) are in the values file because setting them later is an outage.
3. **Demos 01 → 06** on poc1, in order; each `demos/NN-*/README.md` has a *Summary context*, the
   commands, and its recorded `output/transcript.txt`.
4. **SETUP Step 9** — poc2 and ClusterMesh, trust established with cert-manager **before** joining
   (Route A). Then **demos 07 → 08**.
5. **Demo 09** (wildcard TLS + three route types) and **demo 10** (flow export → OTel); SETUP Step 10.
6. **Demos 11, 13, 14** — the forensic set: kube-proxy vs Cilium on a control cluster (SETUP
   Step 11), the mTLS/ztunnel decision and the tuning-blog test (SETUP Step 12). Each pauses or
   snapshots and restores the clusters it touches; read them for the *method* as much as the numbers.
7. **`scripts/verify.sh`** — regenerate every piece of evidence on *your* cluster and diff it
   against [docs/VERIFICATION_RUN.md](docs/VERIFICATION_RUN.md). `scripts/check-routes.sh` is the
   external-access proof for demo 09.
8. **[docs/REFERENCES.md](docs/REFERENCES.md)** — every external source the PoC was built against,
   with what each was used for; the place to check a claim's origin.
9. Keep **[docs/GOTCHAS.md](docs/GOTCHAS.md)** open throughout — 72 traps, each with the real error
   text.

## What is done, and what is left

| | Item | State |
|---|---|---|
| ✅ | poc1 (3 CP + 2 W) and poc2 (1 CP + 1 W), Cilium 1.20.1, no kube-proxy, no other CNI | built, `cilium status` OK on both |
| ✅ | Demos 01–10, each with a recorded transcript | done |
| ✅ | Networking design, two reserved pools, host route, hosts block generated from live state | done |
| ✅ | Enterprise CA from day 1; ClusterMesh on cert-manager certs (`issuer=CN=clustermesh-root-ca`) | done |
| ✅ | **Bank app across the mesh** (demo 15): 5 components, PVC-backed Postgres and Redis, active-active, zero-loss failover, database-restart drills, **a hot standby in the other cluster streaming through the mesh** with promotion and gated failback tested, **load balancing across a 3+3 pool measured per pod** with live scaling and a Maglev twin | done; `https://bank.poc.local` and `https://bankapi.poc.local`; `exercise.sh`, `resilience.sh`, `dbfailover.sh`, `scale.sh` |
| ✅ | **Monitoring (demo 16)**: kube-prometheus-stack on poc1, Grafana on the Gateway, Cilium/Hubble ServiceMonitors + the chart's six dashboards, exemplars proven with a `traceparent`, L7 visibility for the bank namespace | done; `https://grafana.poc.local` (admin / poc-grafana); `demos/16-monitoring/` |
| ✅ | `scripts/verify.sh` → VERIFICATION_RUN.md (916 lines, 22 sections, from the toolchain to the enterprise CA) | regenerable |
| ✅ | **poc3 "classic" cluster (kindnet + kube-proxy) — forensic comparison**: rule-count scaling, programming latency, throughput, conntrack/CPU under load | done — demo 11, with the three-cause forensic on Cilium's default install; poc3 is paused (`scripts/cluster-resume.sh poc3`) |
| ⛔ | **"Cilium mTLS" (mutual authentication, SPIFFE/SPIRE)** | evaluated, **not enabled and not to be adopted**: deprecated in 1.20, removal planned in 1.21 (cilium#47132), ClusterMesh-incompatible — [docs/summary/MTLS_EVALUATION.md](docs/summary/MTLS_EVALUATION.md) |
| ✅ | **ztunnel mTLS (demo 13)** — evaluated on a throwaway cluster: real mTLS on the wire, but cannot run on any cluster with a `cluster.id` (so never with ClusterMesh), breaks L4 **and** L7 policy for enrolled traffic, −73 % throughput | **not the standard**; WireGuard + identity policy is — `demos/13-ztunnel/README.md` |
| ✅ | **Enterprise CA, complete (demo 24)** — Hubble on the same root as the mesh; relay sees all 7 nodes | done |
| ✅ | **Collector per cluster (demo 23)** — gateway pattern, persistent queue, the global-service trap measured | done |
| ✅ | **Multi-cluster observability (demo 22)** — poc2's metrics and traces in the central Grafana/Tempo on poc1; the `cluster` dropdown lists both | done |
| ✅ | **Tempo (demo 21)** — traces stored and clickable from Hubble's exemplars; demo 16 Section C reconciled the reference Hubble values (dashboards in `monitoring`, in folders) | done |
| ✅ | **Spring Boot lab (demo 20)** — petclinic's six JVMs in `springboot`, the app's own spans and the Java agent's spans in the demo 10 collector; `scale.sh down|up` frees the memory it needs by parking the bank and demo 09 Deployments | done; `https://petclinic.poc.local` |
| ✅ | **Zero-trust cell (demo 19)** — the bank runs default-deny on both clusters under a clusterwide baseline and rendered per-component policies; this is the standing posture now | done; `demos/19-zero-trust-cell/` |
| ✅ | **OBI (demo 18)** — zero-code distributed tracing and RED metrics for the bank on both clusters, one collector, Cilium untouched | done; `demos/18-obi/check.sh`, `tracetree.py` |
| ⛔ | **Tetragon (demo 17)** | cannot run on Docker Desktop 4.27.2 (`# CONFIG_SECURITY is not set`; fixed in 4.30.0) and needs the `/procHost` extraMount now in `clusters/poc*.yaml` — [demos/17-tetragon/README.md](demos/17-tetragon/README.md); resumes after the Docker Desktop upgrade on a cluster built with the mount |
| ⏳ | **BGP with an FRR router (demo 12)** | researched and planned in [docs/summary/BGP_FRR_PLAN.md](docs/summary/BGP_FRR_PLAN.md); parked |
| ✅ | Hubble UI through the Gateway, including its **data stream** | HTML/JS/CSS at 200, and the relay shows the browser's `POST /api/control-stream` and `/api/service-map-stream` → 200 arriving as identity `ingress` via `https://hubble.poc.local` (demo 09 Part 10) |
| ⏳ | Wildcard **name** resolution (dnsmasq, `*.poc.local`) | documented in demo 09 Part 3c, not run (needs sudo) |
| ⏳ | The **Linux-server** path in NETWORKING_DESIGN §5 | its routing-table shape measured on the Docker VM (a Linux host running dockerd); not yet run on a bare Linux server |
| ⛔ | netkit, bandwidth manager/BBR, BIG TCP | **cannot run** on the 6.6.12-linuxkit kernel — demo 06 Part 4 proves each; needs a different VM kernel |
| ✅ | **Traces in Grafana** — Tempo behind the demo 10 collector; Explore → Tempo (Search / TraceQL / by id) or an exemplar dot on the Hubble L7 dashboard; the same trace id at every hop | done — demo 21 Part 4 |
| ⛔ | Application **spans** from Hubble | not a Cilium 1.20 capability — hubble-otel archived, CFP closed; demo 10 exports flow *events* instead |

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
"Is the service mesh on?" — the Envoy L7 datapath is on by default, the features built on it are enabled
one value at a time; the table of what a plain install gives you versus what poc1 runs is
[SETUP Step 5.4](docs/SETUP.md#step-54--is-the-service-mesh-on--what-a-plain-install-enables-and-what-this-poc-adds).

Both are installed with **eBPF masquerading and eBPF host routing** from day 1 (`bpf.masquerade: true`;
`Host: BPF` in `cilium status`) — the chart default leaves the netfilter bypass off, see [docs/TUNING.md](docs/TUNING.md).

## Versions this was built and verified against

| Component | Version |
|---|---|
| kind | 0.33.0 |
| Kubernetes (node image) | v1.36.4, pinned by digest |
| Cilium | 1.20.1 — the newest chart and upstream tag as of 2026-09-11 (checked; see `docs/summary/MTLS_EVALUATION.md` §7) |
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
| 04 | WireGuard | Node-to-node encryption enabled with one helm value and verified on the wire — then deliberately switched **off** (the values ship `encryption.enabled: false`) |
| 05 | Gateway API | Cilium as the Gateway controller, address from Cilium's own LB IPAM |
| 06 | Performance | iperf3 pod-to-pod across nodes, with 25–38 % run-to-run noise measured honestly; netkit, bandwidth manager/BBR and BIG TCP **cannot run on this VM kernel** (6.6.12 < 6.7; sysctl absent; BBR not compiled) and the demo proves each |
| 07 | ClusterMesh | A global Service backed by pods in a second cluster, with failover |
| 08 | Enterprise CA | cert-manager root in poc1 issuing every cluster's mesh certificates; trust before join |
| 09 | Wildcard TLS + 3 route types | cert-manager wildcard and exact certs on one Gateway; `HTTPRoute`, `GRPCRoute`, `TCPRoute` from one 14 MB image — and a native Go client (`-mode client`) that tests all three, which is how the missing-ALPN gotcha (#33) was found |
| 10 | Flow tracing -> OpenTelemetry | Hubble dynamic flow export per node, tailed by an OTel Collector into OTLP; every flow persistent and queryable. **Events, not spans** -- hubble-otel is archived, see gotcha #30 |
| 24 | **ClusterMesh the enterprise way, complete** | from demo 08 to 24: Hubble joins the mesh API server on the one cert-manager root (`Connected Nodes: 5/7 → 7/7`, zero handshake failures), the mesh declared the guide's way (`clusters.yaml` + per-cluster files), the order it should have followed, and the 3.5-minute outage a "TLS-only" change caused by replacing the apiserver pod (#72) |
| 23 | **A collector per cluster** | supersedes demo 22's collector part: the gateway is a per-cluster service (same name everywhere, never global — seven backends and the wrong cluster stamp measured), HA in-cluster with 2 replicas + PDB + a persistent queue proven by killing the collectors with the hub down and watching 281 spans leave after the restart |
| 22 | **One Grafana for the mesh** | poc2 becomes a spoke of the observability hub on poc1: a full Prometheus on poc2 (release `edge`) remote-writing across the mesh through a role-named global Service, a collector per cluster forwarding to the central Tempo, Cilium metrics on poc2 with `cluster=poc2`; the same query answered locally and centrally, both clusters in one panel, and the trap of a hub Service selecting the spoke's look-alike (#69) |
| 21 | **Tempo: exemplar → trace** | Grafana Tempo behind the demo 10 collector; the Grafana datasource links exemplar trace ids to it; an L7 visibility policy makes Hubble read the Java agent's `traceparent`; the same trace id measured at every hop (Hubble exemplar → Prometheus → Tempo → Grafana's trace view) |
| 20 | **Spring Boot microservices + Java observability** | The canonical spring-petclinic-microservices (6 JVMs, Spring Boot 3.4) in `springboot` on the Gateway as `petclinic.poc.local`, with three measured fixes (config-server probes, the Boot 3.4 Zipkin key, Eureka's stale-IP window #65); OBI finds and classifies the JVMs but its kernel tracer stops on the same missing LSM hook (#60); the OpenTelemetry Java agent gives the zero-code spans instead |
| 19 | **A zero-trust cell across the mesh** | The Cilium blog's model (policy rendered from declared visibility, default-deny by existence, a platform-owned boundary) done by hand for the bank on both clusters: `intent.yaml` → `render.py` → 7 policies + 1 clusterwide baseline (DNS, in-cell across the mesh, an FQDN allowlist, an API-server deny); 40/40 inside the cell, replication and the Gateway intact; the mesh trap measured (400 drops, #62); RBAC governance; intent change → policy change |
| 18 | **OBI: zero-code traces across the mesh** | OpenTelemetry eBPF Instrumentation on both clusters, scoped to the four bank deployments: one payment as a 16-span tree spanning poc1 → poc2 → Postgres/Redis, spans from both clusters into the demo 10 collector through a global Service, RED metrics per route in the demo 16 Prometheus, Hubble exemplars filling on their own — and the page's Cilium `bpf.tc.priority` change shown unnecessary with tcx. The vendor case (Postgres/Redis server-side) is found and classified but blocked by the same missing LSM hooks as demo 17 (#60) |
| 17 | **Tetragon — blocked, measured** | Installed on poc1: every agent crash-loops because this Docker Desktop (4.27.2) kernel has no `CONFIG_SECURITY`, restored upstream in 4.30.0; and kind nodes need a creation-time `/procHost` mount or events silently lose their pod (#60). Both fixes written down; Parts 3+ wait for the Docker Desktop upgrade |
| 16 | **Prometheus + Grafana, then Hubble on dashboards** | kube-prometheus-stack 90.1.1 first (Grafana at `https://grafana.poc.local`, 32/32 targets), then one Cilium helm change: 6 ServiceMonitors, 6 dashboards, 52/52 targets — and what the dashboards needed that the default metric list did not give them: contexts, a `cluster` label, L7 visibility policies, and a context change the "dynamic" config refused (#57–#59) |
| 15 | **A bank across two clusters** | Five components + Postgres/Redis on PVCs, one image, split half/half across poc1 and poc2 over global Services: the whole call path in one response, idempotent payments across the mesh, **active-active** 23/17, and **zero failed requests** through a scale-to-0 outage and recovery (default and `affinity: local`) |
| 14 | **TCP_CRR tuning blog, tested** | Bigger maps (at 12 % occupancy), shorter timeouts, socket LB for pods (forced off by Gateway API), client sysctls — none moved the connection rate; this rig's ceiling is Hubble (demo 11), and that is the knob |
| 13 | **ztunnel mTLS** | Cilium 1.20's beta mTLS (Istio ztunnel, HBONE) proven on the wire on a throwaway cluster — and shown to be incompatible with any `cluster.id`, to break L4/L7 policy on enrolled traffic, and to cost 73 % of throughput; **not our standard** |
| 11 | **kube-proxy vs Cilium, forensic** | A third cluster (`poc3`: kindnet + kube-proxy iptables, its own docker network) and one script on both: 48 vs 11,078 iptables rules at 1,000 Services, ~2× faster programming, conntrack out of the kernel — **and** the default install losing on throughput and churn until three causes were isolated (legacy host routing, VXLAN, Hubble's per-flow CPU) |

## Regenerating the evidence

Every README here quotes captured output, and quoted output goes stale. `scripts/verify.sh` re-runs
all of it in one pass so you can compare against your own cluster rather than trusting a snapshot
from someone else's laptop:

```bash
scripts/verify.sh                              # to the terminal
scripts/verify.sh > docs/VERIFICATION_RUN.md   # as a document
```

The committed result is **[docs/VERIFICATION_RUN.md](docs/VERIFICATION_RUN.md)** — 916 lines of
real console output in 14 sections: versions, cluster state, full Cilium status, every demo
through 10, the native route client, and the bank across the mesh.

Two notes on reading it. It is **read-only** apart from HTTP requests to the demo app. And it
**always exits 0**, deliberately: several checks are *supposed* to fail — a `curl` that times out
is exactly what an L3 policy denial looks like, and it is recorded as `[exit code: 28]` rather than
hidden. It is an evidence report, not a pass/fail gate; read the output.

## Every gotcha, in one place

**[docs/GOTCHAS.md](docs/GOTCHAS.md)** lists all 72 traps this build actually hit — not things that
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

## Parked

- **BGP with an FRR router (demo 12)** — researched and planned, not built:
  [docs/summary/BGP_FRR_PLAN.md](docs/summary/BGP_FRR_PLAN.md). Every VIP is reachable by L2 today and
  nothing on the docker network speaks BGP (measured), so the router *is* the demo.

## Status

All ten demos built and recorded; see *What is done, and what is left* above for the open items.
Measured results live in `docs/FINDINGS.md`; regenerate the evidence with `scripts/verify.sh`.
