# cilium-implementation-poc

A reproducible proof-of-concept that demonstrates what **Cilium** and **Hubble** give you over a
stock CNI + kube-proxy Kubernetes cluster — measured, not quoted — built from nothing on
[kind](https://kind.sigs.k8s.io/) on a laptop. (The lab's original name, `cilium-kind-poc`, survives in the git
history and as the marker of the `/etc/hosts` blocks the `hosts-entries.sh` scripts write — `scripts/lab-route.sh`
removes those blocks by that marker; the working directory was renamed to the repository's name on 2026-09-15.)

**Setup guide: [docs/SETUP.md](docs/SETUP.md)** — the kind clusters and the Cilium installation, every command
with its recorded output. The other documents: [OBSERVABILITY-ARCHITECTURE.md](OBSERVABILITY-ARCHITECTURE.md)
(the one picture of the observability stack), [docs/GOTCHAS.md](docs/GOTCHAS.md) (every trap this build hit),
[docs/FINDINGS.md](docs/FINDINGS.md) (the measurements), [docs/REFERENCES.md](docs/REFERENCES.md) (every source
cited), [docs/VERIFICATION_RUN.md](docs/VERIFICATION_RUN.md) (the live verification, regenerable with
`scripts/verify.sh`), and one `README.md` per demo under [`demos/`](demos/).

## Start here — where the kind and Cilium installation lives

Everything is installed by hand and documented one command at a time in **[docs/SETUP.md](docs/SETUP.md)**;
the files those commands use are in [`clusters/`](clusters/) (the kind cluster definitions) and
[`cilium/`](cilium/) (the Helm values). In order:

A new Mac (Apple silicon included): **[docs/NEW-MAC.md](docs/NEW-MAC.md)** — the toolchain with the versions this lab pins, Podman beside Docker, the Docker Desktop settings from the file, then the preflight and the same scripts the CI job runs.

A new session on a new machine: **[docs/HANDOVER.md](docs/HANDOVER.md)** — the operator's standing rules, where the lab, the upstream PRs and the forks stand, what is owed and in which order, the first commands.

| Step | What | Where |
|---|---|---|
| 1 | the toolchain — `brew upgrade kind`, `brew install cilium-cli hubble`, versions verified | [Step 1 — install and verify the toolchain](docs/SETUP.md#step-1--install-and-verify-the-toolchain) |
| 2 | size the Docker Desktop VM (the whole lab lives in it) | [Step 2 — size the Docker VM, and clear the decks](docs/SETUP.md#step-2--size-the-docker-vm-and-clear-the-decks) |
| 3 | **create the first kind cluster**: `kind create cluster --config clusters/poc1.yaml` — 3 control planes + 2 workers, `disableDefaultCNI: true`, `kubeProxyMode: none`, node image pinned to `kindest/node:v1.36.4` by digest ([`clusters/poc1.yaml`](clusters/poc1.yaml)) | [Step 3 — create the poc1 cluster](docs/SETUP.md#step-3--create-the-poc1-cluster) |
| 3.5 | route the docker network from macOS (kind-specific) | [Step 3.5 — route the docker network from macOS](docs/SETUP.md#step-35--route-the-docker-network-from-macos) |
| 4 | the API server endpoint Cilium must use (the load balancer by DNS name, not IP — a TLS SAN lesson) | [Step 4 — find the API server endpoint Cilium must use](docs/SETUP.md#step-4--find-the-api-server-endpoint-cilium-must-use) |
| 5 | **install Cilium**: `helm repo add cilium https://helm.cilium.io/` then `helm install cilium cilium/cilium --version 1.20.1 -n kube-system -f cilium/values-poc1.yaml …` — kube-proxy replacement, Hubble with relay mTLS from day one, cluster name/id ([`cilium/values-poc1.yaml`](cilium/values-poc1.yaml)) | [Step 5 — install Cilium](docs/SETUP.md#step-5--install-cilium) |
| 6 | verify: `cilium status --wait`, `hubble status`, no kube-proxy anywhere | [Step 6 — verify the install](docs/SETUP.md#step-6--verify-the-install) |
| 8 | LoadBalancer addresses from Cilium's own LB IPAM ([`cilium/lb-ippool-poc1.yaml`](cilium/lb-ippool-poc1.yaml)) | [Step 8 — LoadBalancer addresses without a cloud (and without MetalLB or kube-vip)](docs/SETUP.md#step-8--loadbalancer-addresses-without-a-cloud-and-without-metallb-or-kube-vip) |
| 9 | **the second cluster and ClusterMesh**: `clusters/poc2.yaml`, `cilium/values-poc2.yaml`, the shared CA, the join | [Step 9 — the second cluster and ClusterMesh](docs/SETUP.md#step-9--the-second-cluster-and-clustermesh) |

Steps 10 onward install what each demo adds, in the demo's order. There is no Makefile: every step is
meant to be read and typed, with its output recorded beside it.

## Scope: kind is the lab, not the design

**kind was used for the Kubernetes clusters; only the initial setup needs kind-specific instructions.**
Those are [docs/SETUP.md](docs/SETUP.md) Steps 1–5 and 9 (the node image pinned to a Cilium-tested
Kubernetes version, the `kubeProxyMode: none` / no-CNI cluster config, the multi-control-plane API
endpoint by DNS name, the second cluster's disjoint CIDRs) and the **network layer**, which is what a
**Docker-based kind homelab** has instead of a real network:

| In this lab (Docker Desktop, kind) | In a real homelab / production-capable cluster |
|---|---|
| pod and service CIDRs chosen inside the `kind` docker bridge; node IPs are container IPs on that bridge (172.18.0.0/16); the two clusters can only mesh because they share it | a real subnet plan: routable node networks, non-overlapping pod/service CIDRs per cluster, and a route (or a tunnel) between the clusters' networks |
| LoadBalancer addresses handed out by Cilium's LB IPAM from a slice of the docker bridge (`cilium/lb-ippool-poc1.yaml`), reached from macOS through a static route into the Docker VM (Step 3.5) | an LB pool on a real VLAN, announced by L2 or BGP (demo 12 parks BGP for exactly this reason) |
| **DNS:** every hostname — `bank`, `grafana`, `petclinic`, `cf2cnp`, `web`, `grpc`, `deathstar`, `hubble` … `.poc.local` — is written into the MacBook's `/etc/hosts` by each demo's `hosts-entries.sh`, all pointing at the one Gateway address `172.18.255.240`; nothing resolves the names for the pods or for anyone else | a **wildcard A record `*.poc.local` → the Gateway's LoadBalancer address** in the homelab's DNS zone (one record replaces every `hosts-entries.sh`), with exact records only where a listener is exact (`exact.example.test` in demo 09); or external-dns creating records from the HTTPRoutes' hostnames; the pods use the same zone through CoreDNS forwarding (gotcha #63 is the Docker VM's upstream, not a design) |
| **TLS:** one **wildcard certificate `*.poc.local`** on the Gateway's `https-wildcard` listener (`wildcard-poc-local-tls`), issued by **cert-manager from the demo 08 enterprise root** (`ClusterIssuer/ca-issuer`, 90-day validity, renewed automatically), plus an exact-name certificate for the exact listener; the Mac trusts the root by passing `docs/root-ca.crt` to `curl` and the browser | the same Gateway listener and the same cert-manager `Certificate` — issued by the enterprise CA (a real PKI root or intermediate, the root distributed to workstations through the OS trust store, not a `--cacert` flag) or, for a public zone, by an ACME issuer with DNS-01 (the only ACME path that can issue a wildcard); the listener's `certificateRefs` do not change |
| the ClusterMesh API server as a NodePort on a control-plane container IP (`clusters.yaml`) | a LoadBalancer or a DNS name per cluster (`address:` in the guide's `clusters.yaml`), with the shared CA provisioned before the join (demo 08/24) |
| the Docker Desktop VM kernel (6.6, no `CONFIG_SECURITY`) and its memory ceiling: the reason Tetragon and OBI's generic tracer are parked (gotchas #60, #66) | the kernel and the RAM you chose — none of those gotchas apply |
| a Mac as the operator's workstation: the `hubble` CLI, Playwright, `sudo` for hosts entries | a bastion or the operator's Linux box; the same CLI, the same certificates (`scripts/hubble-tls.sh`) |

**The networking design, in one sentence:** one Gateway with one LoadBalancer address, one wildcard
DNS record and one wildcard certificate in front of every HTTP application, exact names and exact
certificates only where a demo proves the difference (demo 09), and mTLS from the enterprise root for
everything that is not a browser (the relay, the mesh API server, the observer, the CLI). The lab
fakes the DNS half with `/etc/hosts` and trusts the root by hand; a real network replaces exactly
those two things and keeps the rest.

**Everything else applies to most Kubernetes clusters as it stands**: the Cilium values (per-cluster
install, ClusterMesh, Gateway API, L7 policy, WireGuard, Hubble metrics and export, relay mTLS from
day one), the enterprise CA with cert-manager, the zero-trust cell, the observability standard
(hub-and-spoke Prometheus with remote write, a collector per cluster, one Tempo, one Loki, the
dashboards and their provisioning), the hubble-observer work and its upstream pull requests, and
every measured gotcha that is not marked Docker/kind. The expectation is that a real network, a real
subnet and CIDR plan, DNS records and servers take the place of the MacBook, the docker bridge and
`/etc/hosts` — and that nothing in the demos from 06 onward has to change for it.

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
8b. **The Hubble Relays require mutual TLS — from day one** (`cilium/values-poc*.yaml`, gotcha #75).
   Configure the CLI once, `scripts/hubble-tls.sh --configure kind-poc1 kind-poc2`, and every
   `hubble …` command in demos 01–25 works as written (measured in demo 25 Part 5g: demo 01's and
   demo 07's commands verbatim, both clusters). Relay port-forwards are `4245:443`; the one `4245:80`
   left in the text is gotcha #47's historical note.
8c. **[OBSERVABILITY-ARCHITECTURE.md](OBSERVABILITY-ARCHITECTURE.md)** is the one picture of the observability
   stack across the mesh — what runs in the hub, what every spoke runs, and why (demos 10, 16, 18, 21–25).
8d. **Demo 26** is the foundational policy skill: a Hubble flow JSON → a CiliumNetworkPolicy, three ways,
   with audit mode first. Read it before writing any policy by hand; demo 19 is where the intent lives.
8e. **Demo 27** runs the fork's cf2cnp 0.5.0 release on a two-component lab: one request, two policies whose
   names cannot collide — the Kubernetes one-name-per-kind-per-namespace rule made concrete.
8f. **Demo 28** turns the policy-verdicts dashboard into a deliverable: its own chart repository, a
   dependency of the observer chart, offered upstream — with the first-release traps written down.
8g. **Demo 29** runs cf2cnp 0.6.0 (enhancement 001) on the mesh: the caller's cluster in the generated
   selector, measured against the 0.5.1 output that enforced the wrong pod; a spoke's verdict on the hub's
   dashboard.
8h. **Demo 30** generates Layer-7 rules from the proxy's own flows (`--l7`): method + path per port, a
   query string tolerated, a path nobody called answered 403 by the proxy, the stranger still dropped at L3.
8i. **Demo 31** closes demo 26's open end: a world destination without a name becomes a CIDR; with the
   DNS-visibility rule the next flows carry the name, and the regenerated policy is `toFQDNs`.
8j. **Demo 32** is the operator's loop: intent before generation (the peer checklist, `exclude=`), a new
   client merged into the existing file without rewriting it, and the file evolving through a pull request
   from a workflow — with what its first real run found.
8k. **Demo 33** hardens the shared `/generate`: a policy for the pod (and the parent chart's wider one narrowed,
   because policies add), an Origin allow-list, and a token measured on for one revision — then off, with the
   reason.
8l. **Demo 34** closes the loop on one page: the verdict dashboard's Loki row runs the cf2cnp action on a
   dropped flow (E7), and a second observer streams every policy verdict with the policy that decided, so
   "which rule allowed it" is one LogQL (E8) — with the container-label trap the second release hit.
8m. **Demo 35** is the platform-scale run: a shared catalog called from three namespaces, an API gateway in
   a fourth, a client namespace that must only go through the gateway — one request, six policies whose
   descriptions read like the architecture (cf2cnp 0.6.3).
8n. **Demo 36** is the trust exercise: which CA signs the Gateway (cert-manager's, from demo 08's root — read
   from the chain, not assumed), and that root put into the OS trust stores and every namespace of both
   clusters, so `--cacert` flags and in-pod curls to Gateway URLs stop being special cases.
9. **[docs/POLICY-TEST-RESULTS.md](docs/POLICY-TEST-RESULTS.md)** is the one-page answer to "what was tested and what happened" for every generated network policy (demos 26–35) and for cf2cnp's own test layers.
10. Keep **[docs/GOTCHAS.md](docs/GOTCHAS.md)** open throughout — 109 traps, each with the real error
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
| ✅ | `scripts/verify.sh` → VERIFICATION_RUN.md (1024 lines, 23 sections, from the toolchain to the flow store) | regenerable |
| ✅ | **poc3 "classic" cluster (kindnet + kube-proxy) — forensic comparison**: rule-count scaling, programming latency, throughput, conntrack/CPU under load | done — demo 11, with the three-cause forensic on Cilium's default install; poc3 is paused (`scripts/cluster-resume.sh poc3`) |
| ⛔ | **"Cilium mTLS" (mutual authentication, SPIFFE/SPIRE)** | evaluated, **not enabled and not to be adopted**: deprecated in 1.20, removal planned in 1.21 (cilium#47132), ClusterMesh-incompatible — [docs/summary/MTLS_EVALUATION.md](docs/summary/MTLS_EVALUATION.md) |
| ✅ | **ztunnel mTLS (demo 13)** — evaluated on a throwaway cluster: real mTLS on the wire, but cannot run on any cluster with a `cluster.id` (so never with ClusterMesh), breaks L4 **and** L7 policy for enrolled traffic, −73 % throughput | **not the standard**; WireGuard + identity policy is — `demos/13-ztunnel/README.md` |
| ✅ | **Enhancement 001 released (demos 29 →)** — cf2cnp 0.6.0 (E1–E6, E10), hubble-policy-verdicts 0.2.0 (E7), the observer fork with both and the E8 example; demo 29 proves E1 and E9 on the mesh, demo 30 E2 (L7 rules), demo 31 E3 (DNS visibility → toFQDNs), demo 32 E4+E5+E10 (the operator's loop; two findings fixed as cf2cnp 0.6.1), demo 33 E6 (hardening), demo 34 E7+E8 (verdict → policy on one page; which policy allowed it); follow-ups from the operator's review as cf2cnp 0.6.2/0.6.3 (descriptions from the rules) and dashboard 0.2.1/0.2.2 (the filter's side, generic wording, the audited tile), proven in demo 35 | **done** — every item proven, issues #1–#10 closed; `enhancements/README.md` |
| ✅ | **Policy Verdicts dashboard as a product (demo 28)** — own repo + chart 0.1.1 on gh-pages, dependency of the observer fork, offered upstream; cf2cnp 0.5.1 | done; `demos/28-policy-verdicts-chart/` |
| ✅ | **cf2cnp 0.5.0 released from the fork and tested (demo 27)** — gh-pages Helm repo, GitHub release, public image; two components, one request, two names that cannot collide | done; `demos/27-cf2cnp-release/` |
| ✅ | **Policy from observed flows (demo 26)** — audit mode → default-deny → flow JSON from four sources → cf2cnp by API / UI / Grafana action → apply → enforce; the `policy` verdict metric on, the *Hubble / Policy Verdicts (Namespace)* dashboard provisioned | done; `demos/26-cf2cnp-policy-from-flows/` |
| ✅ | **Relay mTLS (demo 25 Part 5)** — every `hubble` command now takes `$(scripts/hubble-tls.sh <ctx>)`; earlier demos' commands need it too | done |
| ✅ | **Historical flows in Loki (demo 25)** — hubble-observer → collector → Loki → the 23862 dashboard, both clusters through one relay | done |
| ✅ | **Enterprise CA, complete (demo 24)** — Hubble on the same root as the mesh; relay sees all 7 nodes | done |
| ✅ | **Collector per cluster (demo 23)** — gateway pattern, persistent queue, the global-service trap measured | done |
| ✅ | **Multi-cluster observability (demo 22)** — poc2's metrics and traces in the central Grafana/Tempo on poc1; the `cluster` dropdown lists both | done |
| ✅ | **Tempo (demo 21)** — traces stored and clickable from Hubble's exemplars; demo 16 Section C reconciled the reference Hubble values (dashboards in `monitoring`, in folders) | done |
| ✅ | **Spring Boot lab (demo 20)** — petclinic's six JVMs in `springboot`, the app's own spans and the Java agent's spans in the demo 10 collector; `scale.sh down\|up` frees the memory it needs by parking the bank and demo 09 Deployments | done; `https://petclinic.poc.local` |
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
| 36 | **One root, everywhere** | the design exercise behind every `--cacert docs/root-ca.crt` in this repo: the Gateway's wildcard was cert-manager's all along (ClusterIssuer `ca-issuer` signs with demo 08's `clustermesh-root-ca`, the same root behind the mesh and the relay), so the root — never a leaf — goes where the clients live: the MacBook's keychain and the CI runner's Ubuntu store (`scripts/lab-trust.sh install`, proven by a curl by name with no `--cacert`), and every namespace of both clusters as a ConfigMap through trust-manager's Bundle, mounted by demo 11's client (`200` with the mounted root, curl exit 60 without) — then Kyverno v1.19.1's `MutatingPolicy` mounts it and sets `SSL_CERT_FILE` in every container of any pod carrying one label, so a client declares nothing and curls with no flag (measured offline with the CLI first) |
| 35 | **The shop platform: cross-namespace, one request, six policies (cf2cnp 0.6.3)** | five service namespaces and a client namespace: a shared `catalog` called by `orders` (its own namespace), `merchant`, `reviews` and the `api-gateway` (three others); `payment-gateway` settling with `merchant`; a `shopper` that goes through the gateway and a `stranger` that goes straight at the catalog and payments; every service on nginx with real paths from a ConfigMap; default-deny per namespace under audit on seven endpoints, 85 AUDIT flows from everywhere in one file, one `/generate?exclude=…stranger` → six policies in six namespaces, cross-namespace peers carrying `io.kubernetes.pod.namespace`; the **descriptions written from the rules** — `Allow ingress to catalog in shop-core: from orders on TCP/80; from api-gateway in shop-edge on TCP/80; from merchant in shop-merchant on TCP/80; from reviews in shop-reviews on TCP/80`; enforced: six 200s, the stranger dropped twice, and the shopper straight at the catalog dropped too (only the gateway was ever observed calling it); the dashboard on shop-core (the destination) and on shop-clients (the source) |
| 34 | **Verdict → policy on one page (E7), and which policy allowed it (E8)** | a second observer release from the fork's example values (`--type policy-verdict`, no `--verdict`, the relay's mutual TLS, the agent image) streams every verdict with `ingress_allowed_by` / `egress_allowed_by` / `*_denied_by`; both releases would have shared `{container="hubble-observer"}` in Loki — the chart's container name is the chart's name — so the fork gains `containerName` and the collector a second glob (gotcha #89); the stream in Loki under its own label, one raw line with the policy's name, kind, namespace and revision, and "which policy allowed it" as one LogQL (shop-frontend 190, shop-backend 142, …; the unnamed drops are default-deny, #82; `reserved:host` lines name Cilium's implicit `allow-localhost-ingress`); the verdict dashboard's Loki row (chart 0.2.0) runs the cf2cnp action on a dropped flow — the same menu as demo 26, on the page where the verdict was read |
| 33 | **Hardening the shared `/generate` (E6)** | today a lab pod reaches `/generate` by the Service name and every Origin gets `*`; the subchart's CiliumNetworkPolicy (`reserved:ingress` + `reserved:host` on 8080, kube-dns egress) **changed nothing** while the observer chart's own policy said `[cluster, world]` — measured: the lab pod forwarded by the wider policy (gotcha #88, policies add) — so the parent's entities are narrowed too: the lab pod dropped, the Gateway 200, host and ingress forwarded by both policies; the Origin allow-list: a foreign origin gets no CORS header, the Grafana origin is echoed with `Vary: Origin`, the preflight answered; the token on for one Helm revision: 401 with `WWW-Authenticate` / 401 wrong / 200 right, preflight, `/health` and the page open, and the Grafana action's request 401 — the reason the shared instance runs without one (the revert recorded); the action end to end under the controls |
| 32 | **The operator's loop: intent, merge, pull request (E4, E5, E10)** | the release binary on the operator's machine, checksum verified; every caller of demo 27's storefront (pos forwarded, the stranger **dropped** — and still a rule, because cf2cnp reads flows, not verdicts) → `exclude=` removes exactly that rule, everything excluded is a 400, the page's peer checklist sends it; a new client (`kiosk`) dropped under the enforced policy → `cf2cnp merge` adds one rule to demo 27's file, a second merge adds nothing — and 0.6.0 re-serialised the whole file (alphabetical keys, 4-space indent), which 0.6.1 fixes by editing the YAML node tree: the diff is the seven added lines; applied, kiosk 200, pos 200, the stranger dropped; the E10 workflow template on a throwaway policies repository: run 1 failed on the archive's name (checksum), run 2 on the repository's *allow Actions to create PRs* setting, run 3 opened PR #1 (+7 −0, validated against the 1.20.1 CRD offline, nothing applied) |
| 31 | **DNS visibility → `toFQDNs` (E3)** | demo 26's `pos` calls `example.com` and its flows name the world by IP only (no `destination_names`: nothing puts its lookups through the DNS proxy), so the generated egress policy says `toCIDR 104.20.23.154/32`; `/generate?dnsVisibility=true` adds the kube-dns rule with `rules.dns: [{matchPattern: "*"}]` (the plan's E3 — ten lines, the diff), applied, the proxy reports every query (`dns-request proxy … example.com. A`) and the next world flow carries `destination_names: [example.com]`; regenerated without any option the policy is `toFQDNs: matchName: example.com`; enforced: `example.com` 200, `cilium.io` resolves but its SYN is `Policy denied DROPPED` — and Hubble names the dropped destination (`cilium.io`); the page with the DNS-visibility box; the Hubble DNS dashboard for the namespace; one finding filed on the fork (the kube-dns rule appears twice once the pod's own lookups are among the flows) |
| 30 | **Layer-7 rules from the proxy's flows (E2)** | demo 27's shop lab in its own namespace with nginx serving real paths and callers that use several; an L7 visibility policy puts `:80` on the proxy so every request reaches Hubble as `flow.l7` (method, full URL, headers) — 44 REQUEST records from the intended callers; the same bytes through `/generate` and `/generate?l7=true` differ only by `rules.http`: one port rule per port, `method: GET` and an anchored, escaped path that tolerates a query string (`^/api/orders(\?.*)?$` from `/api/orders` and `/api/orders?id=42` both); enforced in place of the visibility policy with a default-deny: the observed paths 200 (`/checkout?promo=1` included), `/admin` — never observed — `403 Forbidden` from the proxy on both components, the stranger dropped at SYN; the page with the Layer-7 box; the proxy's decisions as `match=l7/http` on the verdict dashboard and the 403s on Hubble's L7 HTTP dashboard |
| 29 | **Policy from a cross-cluster flow (E1), its verdict on the hub (E9)** | cf2cnp 0.6.0 released from the fork (chart, image, four binaries with checksums) and deployed as the observer chart's dependency with the dashboard chart 0.2.0; a `cache` in poc1 behind a global Service, a `worker` in poc2 and a same-labelled twin in poc1; default-deny under audit, the AUDIT flows from the poc2 caller only, the same bytes through 0.6.0 (deployed) and 0.5.1 (the image run locally) — **one line differs**, `io.cilium.k8s.policy.cluster: poc2`; each policy enforced in turn: the cluster-blind one dropped the real caller and admitted the twin, the 0.6.0 one the reverse (verdicts with the policy name); the worker's egress policy applied **in poc2** (kube-dns without the label, the cache with `poc1`), its forwarded and dropped verdicts decided on poc2's node, in poc1's Prometheus under `cluster="poc2"` and on the dashboard's `cluster` variable; why the destination node has no INGRESS flow until a policy selects the endpoint (`parser.go`); Part 9: dashboard chart 0.2.1's `namespace is the` variable puts the egress drops that left the namespace on the page |
| 28 | **The Policy Verdicts dashboard, enterprise-ready** | from a JSON file and a script in this PoC to its own repository ([hubble-policy-verdicts](https://github.com/ephico2real2/hubble-policy-verdicts)): a chart with both delivery paths (Grafana sidecar ConfigMap, Grafana Operator CR), released on gh-pages with a GitHub release, CI that renders it under a camelCase alias — because the first deploy as the observer chart's aliased dependency was refused by the API server (`.Chart.Name` is the alias, #85) — consumed by the hubble-observer fork (`policyVerdictsDashboard.enabled`), the hand-made ConfigMap retired, offered upstream (onzack/hubble-observer#12, PR #13); cf2cnp 0.5.1 names components in the page summary |
| 27 | **cf2cnp 0.5.0 from the fork, deployed and tested** | the release (gh-pages Helm repo + public ghcr image) reaching poc1 as the hubble-observer chart's dependency, on a lab built for the naming rule: a `shop` frontend and a `shop` backend (same `app.kubernetes.io/name`, different component), one default-deny for both in audit mode, 30 audit flows collected by intent and posted **once** → two policies `shop-frontend` and `shop-backend`, labelled, enforced (stranger dropped at both, the intended paths forwarded *by* the named rules), the page on all 30 flows, the Grafana action; the dashboards and Hubble UI group both components as `shop` — the policy names are what tell them apart; the audit flag that landed on a terminating pod (#84) |
| 26 | **Policy from observed flows, three ways** | the foundational skill under every "generate policy from traffic" feature, done with open-source parts: where a Hubble flow JSON comes from (the live relay, Loki, the observer log, the node's export file — all four produced the byte-identical policy), what cf2cnp reads in it, the measured fact that nobody reports INGRESS until the workload has a policy — so **default-deny in policy audit mode first** (`AUDIT` verdicts, zero drops), then the flow → policy through the API, the Web UI and the Grafana action, applied under audit, then enforced (`stranger` DROPPED, `pos` forwarded *by* the generated rule); the verdicts read in Hubble UI, the chart's dashboards, the observer's Loki dashboard and a policy-verdicts dashboard of our own on the new `policy` metric; `ingress: []` rejected (#80), cf2cnp's one-name-per-destination (#81), default-deny names no policy (#82); Hubble UI has no extension API but can be framed, Grafana refuses framing by default — measured; then cf2cnp itself improved on the fork and sent upstream ([issue #2](https://github.com/onzack/cf2cnp/issues/2), [PR #3](https://github.com/onzack/cf2cnp/pull/3)): `download_url` honours the proxy headers (#83), many flows per request merged per workload, policy names a function of the whole selector (one name per kind per namespace — the replacement measured), labels on every policy, `?name=`, the page's summary/copy/download; released as 0.5.0 from the fork (gh-pages Helm repo + ghcr image) and running here |
| 25 | **Historical flows, the open-source way** | what Isovalent's Timescape does, built from parts: onzack/hubble-observer (chart vendored from main — the published 2.5.0's probes kill it, #73) streams DROPPED flows from poc1's mesh-wide relay as JSON, the demo 10 collector ships them to a Loki single binary with the labels the grafana.com 23862 dashboard expects, provisioned into the Hubble folder; a drop caused in poc2 lands in Loki through poc1's relay; cf2cnp behind the Gateway; then the relay itself closed: a pod with nothing could read every flow of both clusters in plaintext (#75), so both relays now require mTLS from the enterprise root, with the observer, the UI and the CLI each holding their own cert-manager certificate; a second pass upstream: issues #7/#8, PR #9 (the chart's policy never worked: no DNS rule, Service port instead of pod port, #76) |
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

## Evidence — screenshots and running pods, per demo

Every demo that runs today carries an **Evidence** section at the end of its README: the Grafana
dashboards, the Hubble UI and the web UIs as the browser saw them with traffic running, and the
`kubectl get pods -o wide` of its namespaces in both clusters plus the Cilium command that proves the
claim. Taken by [`scripts/evidence/capture.js`](scripts/evidence/capture.js) (one Playwright runner,
one `evidence.json` per demo) and [`scripts/evidence/collect.sh`](scripts/evidence/collect.sh) (one
table, `scripts/evidence/table.txt`); both re-run in place. Demos whose workload is scaled down,
paused or blocked by the lab carry a marker file where the images will go and a row in
[missing-captures.md](missing-captures.md).

| Demo | Evidence |
|---|---|
| [01-hubble](demos/01-hubble/README.md#evidence) | 1 capture, pods + Cilium output |
| [02-l7-policy](demos/02-l7-policy/README.md#evidence) | 2 captures, pods + Cilium output |
| [03-kube-proxy-free](demos/03-kube-proxy-free/README.md#evidence) | pods + Cilium output |
| [04-wireguard](demos/04-wireguard/README.md#evidence) | pods + Cilium output |
| [05-gateway-api](demos/05-gateway-api/README.md#evidence) | 2 captures, pods + Cilium output |
| [06-perf](demos/06-perf/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [07-clustermesh](demos/07-clustermesh/README.md#evidence) | 1 capture, pods + Cilium output |
| [08-certmanager-ca](demos/08-certmanager-ca/README.md#evidence) | pods + Cilium output |
| [09-routes](demos/09-routes/README.md#evidence) | 3 captures, pods + Cilium output |
| [10-tracing](demos/10-tracing/README.md#evidence) | pods + Cilium output |
| [11-kube-proxy-vs-cilium](demos/11-kube-proxy-vs-cilium/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [13-ztunnel](demos/13-ztunnel/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [14-tcp-crr-tuning](demos/14-tcp-crr-tuning/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [15-bank](demos/15-bank/README.md#evidence) | 4 captures, pods + Cilium output |
| [16-monitoring](demos/16-monitoring/README.md#evidence) | 11 captures, pods + Cilium output |
| [17-tetragon](demos/17-tetragon/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [18-obi](demos/18-obi/README.md#evidence) | 2 captures, pods + Cilium output |
| [19-zero-trust-cell](demos/19-zero-trust-cell/README.md#evidence) | 2 captures, pods + Cilium output |
| [20-springboot](demos/20-springboot/README.md#evidence) | **captures pending** (see missing-captures.md) |
| [21-tempo](demos/21-tempo/README.md#evidence) | 8 captures, pods + Cilium output |
| [22-multicluster-observability](demos/22-multicluster-observability/README.md#evidence) | 9 captures, pods + Cilium output |
| [23-collector-per-cluster](demos/23-collector-per-cluster/README.md#evidence) | pods + Cilium output |
| [24-clustermesh-enterprise](demos/24-clustermesh-enterprise/README.md#evidence) | 1 capture, pods + Cilium output |
| [25-hubble-observer-loki](demos/25-hubble-observer-loki/README.md#evidence) | 8 captures, pods + Cilium output |
| [26-cf2cnp-policy-from-flows](demos/26-cf2cnp-policy-from-flows/README.md#evidence) | 5 captures + 7 from the two Playwright scripts, pods + policies + verdicts |
| [27-cf2cnp-release](demos/27-cf2cnp-release/README.md#evidence) | 4 captures + 7 from the two Playwright scripts, pods + policies by label + verdicts + the release |
| [28-policy-verdicts-chart](demos/28-policy-verdicts-chart/README.md#evidence) | 2 captures + 3 from the page script, the releases + ConfigMaps + Helm release |
| [35-shop-platform](demos/35-shop-platform/README.md#evidence) | 3 captures (the dashboard as destination and as source, the Hubble UI map), pods in six namespaces + every policy's description + the nine probes; the flows and both policy files under `policies/` |
| [34-verdict-to-policy](demos/34-verdict-to-policy/README.md#evidence) | 2 captures (Explore with the E8 LogQL, the dashboard with its Loki row) + the action script's 4 steps, the releases + the container names + the row's panels |
| [33-hardening](demos/33-hardening/README.md#evidence) | 1 capture (the verdict dashboard on the observer namespace) + the action script's steps, the policies with their entities + the container's flags + the release's values |
| [32-operator-loop](demos/32-operator-loop/README.md#evidence) | 1 capture (the PR's files tab) + 3 from the page script, pods + the policy's peers + the PR list + the release; the flows, the policy before and after (0.6.0 and 0.6.1) under `policies/` |
| [31-dns-visibility](demos/31-dns-visibility/README.md#evidence) | 1 capture (the DNS dashboard) + 3 from the page script, pods + the policy's rules (FQDN, kube-dns, DNS rule); the flows before and after, and three policies under `policies/` |
| [30-l7-rules](demos/30-l7-rules/README.md#evidence) | 2 captures (the L7 HTTP dashboard, the verdict dashboard) + 3 from the page script, pods + the policies with their L7 paths + the eight measured calls; the flows and both policies under `policies/` |
| [29-cross-cluster-policy](demos/29-cross-cluster-policy/README.md#evidence) | 2 captures (the dashboard per cluster), pods in both clusters + the policies with their cluster label + the global Service; the flows and four policies under `policies/` |

## Docker and kind: the limits this lab hit, and what they mean for a real cluster

These are measured, each with its gotcha, not assumed. None of them is a Cilium limit.

| Limit | What it blocked here | On a production-capable cluster |
|---|---|---|
| Docker Desktop 4.27.2's kernel has no `CONFIG_SECURITY` (no LSM hooks) — gotcha #60 | **Tetragon** (every agent crash-loops), **OBI's generic tracer** and its Java agent injection | any distribution kernel; fixed in Docker Desktop 4.30 for this laptop |
| the 6.6.12-linuxkit kernel — demo 06 Part 4 | **netkit**, the **bandwidth manager with BBR**, **BIG TCP** | a 6.7+ kernel with the features compiled in |
| one VM for seven kind nodes, two Cilium installs, Envoy, the whole observability stack — gotchas #66, #77 | control-plane restarts under load 100–300, the hub Prometheus OOM-killed 51 times, petclinic and poc3 kept scaled down / paused | real nodes with their own memory; the observability hub sized for the sum of its spokes |
| the Docker VM's DNS upstream unreachable from pods — gotcha #63 | CoreDNS forwarding to 1.1.1.1 / 8.8.8.8 instead | the site resolvers |
| all node IPs on one docker bridge; LoadBalancer addresses from a slice of it; `/etc/hosts` on the Mac | the only reason the two clusters can mesh; every hostname typed by hand | a subnet plan, an LB pool on a VLAN (L2 or BGP — demo 12 is parked for exactly this), a wildcard DNS record |
| no second node for the poc2 spoke, one worker | the observer's two replicas land on the same node; the PDB cannot help | anti-affinity that spreads |
| Hubble UI open source — demo 16 Part 11b | no time range, no flows-per-minute chart, no cluster picker in the UI (enterprise, Timescape) | the same: this lab builds the store with Loki instead (demo 25) |

## Formatting the documents — automatic

`scripts/mdfmt` (`mdfmt` on the PATH) formats and lints every `*.md` with `markdownlint-cli2`; the
rules are in `.markdownlint-cli2.yaml`. It runs by itself in two places: a Claude Code hook
(`.claude/settings.json` → `scripts/mdfmt-hook.sh`) fixes each Markdown file the moment the assistant
writes or edits it and reports anything it cannot fix, and a git pre-commit hook
(`.githooks/pre-commit`, enable once with `git config core.hooksPath .githooks`) fixes and re-stages
every staged `*.md` and refuses a commit that still has findings. What it will not fix by itself and
will name instead: a `|` inside a table cell (escape it `\|`), a wrapped line that begins with `#`, `-`
or `+` (rejoin it), a second top-level heading (make it a section).

## Regenerating the evidence

Every README here quotes captured output, and quoted output goes stale. `scripts/verify.sh` re-runs
all of it in one pass so you can compare against your own cluster rather than trusting a snapshot
from someone else's laptop:

```bash
scripts/verify.sh                              # to the terminal
scripts/verify.sh > docs/VERIFICATION_RUN.md   # as a document
```

The committed result is **[docs/VERIFICATION_RUN.md](docs/VERIFICATION_RUN.md)** — 1024 lines of
real console output in 14 sections: versions, cluster state, full Cilium status, every demo
through 10, the native route client, and the bank across the mesh.

Two notes on reading it. It is **read-only** apart from HTTP requests to the demo app. And it
**always exits 0**, deliberately: several checks are *supposed* to fail — a `curl` that times out
is exactly what an L3 policy denial looks like, and it is recorded as `[exit code: 28]` rather than
hidden. It is an evidence report, not a pass/fail gate; read the output.

## The lab in CI — the same scripts on a GitHub-hosted runner

The whole lab is also built, exercised and measured on a GitHub Actions runner (4 vCPU, 16 GB): the plan and
every run's measurements are in **[enhancements/004-lab-in-ci.md](enhancements/004-lab-in-ci.md)**. Three
`workflow_dispatch` workflows, each from the same scripts a MacBook uses (`scripts/lab-up.sh`, `lab-stack.sh`,
`lab-images.sh`, `lab-apps.sh`, `lab-policies.sh`, `lab-report.sh`, `scripts/capture/`). The only per-host part is
the bootstrap before them — `scripts/bootstrap/ubuntu.sh` on the runner, `scripts/bootstrap/macos.sh` on a Mac, the
pins in `scripts/bootstrap/versions.env` — and both end in the same `scripts/lab-preflight.sh` table:

| Workflow | What it proves |
|---|---|
| `lab-spike-kind.yaml` | two kind clusters, each complete and independent, then the mesh (route A: cert-manager's root); Cilium's own multi-cluster connectivity test, 87/87 |
| `lab-route-b.yaml` | the same on Helm certificates (SETUP 9.3b), the mesh checks of 9.5 and demo 07's global service and failover, with the guide's numbers |
| `lab-observability.yaml` | the lab's images built and loaded first, the stacks of demos 09/16/21/10–23/25/18, the labs of 26–35 with the bank, the cell, demo 11's client and demo 20's petclinic; traffic under audit; the cf2cnp chapters (raw flows kept, policies generated through the API, validated three ways, applied, the applications re-tested); the enforced traffic with a strict wait on Prometheus, Loki and Tempo from both clusters; the demos' own checks as a report on the run page; the pages captured with expectations — every verdict-dashboard panel has data but the ones named with a reason, the Hubble UI shows the labs — and published to the `ci-captures` branch, so the pictures are on the run page |

A run's page holds the report and the captures; its artifact holds every log, the raw flows and the generated
policies. What the runner refused (netkit before its kernel, BIG TCP under VXLAN, the bandwidth manager in kind) is
in the gotchas, #92 onward.

## Every gotcha, in one place

**[docs/GOTCHAS.md](docs/GOTCHAS.md)** lists all 109 traps this build actually hit — not things that
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

See NETWORKING_DESIGN.md §0 and §3, SETUP.md Step 8 and `cilium/lb-ippool-poc1.yaml`.

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

## Enhancements

**[enhancements/](enhancements/README.md)** — proposals that grew out of the demos, each with its motivating
measurement, an issue, a reviewed plan with the code, and the demo that will prove it. First:
[001 — policy from observed flows, enterprise-ready](enhancements/001-policy-from-flows-enterprise.md)
(tracking issue [#11](https://github.com/ephico2real2/cilium-implementation-poc/issues/11)).

## Parked

- **BGP with an FRR router (demo 12)** — researched and planned, not built:
  [docs/summary/BGP_FRR_PLAN.md](docs/summary/BGP_FRR_PLAN.md). Every VIP is reachable by L2 today and
  nothing on the docker network speaks BGP (measured), so the router *is* the demo.

## Status

All ten demos built and recorded; see *What is done, and what is left* above for the open items.
Measured results live in `docs/FINDINGS.md`; regenerate the evidence with `scripts/verify.sh`.
