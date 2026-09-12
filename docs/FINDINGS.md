# FINDINGS — measured results

Everything here was captured on the build machine. Nothing is estimated or reproduced from
documentation. Where a claim could not be measured, it says so.

Build machine: macOS Darwin 24.6.0, x86_64, 16 CPU / 32 GB host; Docker Desktop VM 15.62 GB,
kernel `6.6.12-linuxkit`. Cluster `poc1`: kind 0.33.0, Kubernetes v1.36.4, Cilium 1.20.1.

## Environment constraints discovered

| Finding | Value | Consequence |
|---|---|---|
| Docker VM memory (default) | 7.66 GB | Too small for 7 nodes; raised to 15.62 GB |
| Docker VM kernel | `6.6.12-linuxkit` | **netkit unavailable** (needs ≥6.7); demo 06 uses bandwidth manager + BIG TCP instead |
| kind default node image | v1.37.0 | **Not used.** Cilium 1.20.1 is e2e-tested on 1.33–1.36 only; pinned v1.36.4 by digest |
| kind external load balancer | `envoyproxy/envoy:v1.36.2` | Envoy, not HAProxy as older guides say |
| Hubble CLI vs Relay | 1.19.4 vs 1.20.1 | Version warning on every command. `cilium/hubble`'s newest release *is* 1.19.4, so no matching CLI exists; warning is expected, not a misconfiguration |
| macOS host → container network | no route, `curl` → `000` | Docker Desktop runs containers in a VM. Fixed with `kernelForUDP` + a host route, **not** with any in-cluster load balancer |
| Docker Desktop host bridge | **`bridge100`**, not `bridge101` | macOS assigns the number; it is not portable between machines |
| `CiliumLoadBalancerIPPool` | `cilium.io/v2` | `v2alpha1` is deprecated and warns |
| `CiliumL2AnnouncementPolicy` | `cilium.io/v2alpha1` **only** | Did *not* graduate with the pool; one manifest needs two apiVersions |
| kind multi-node + Docker restart | cluster destroyed | Container IPs are reassigned; etcd peers and cert SANs break. Settings must be final before cluster creation |
| Gateway `metadata.annotations` pin | **not propagated** | The generated Service never received it; the address matched by coincidence. Use `spec.infrastructure.annotations` |
| LB IPAM pools | two, disjoint, selector-split | `.240–.250` Gateway-only (`io.cilium.gateway/owning-gateway` Exists), `.200–.239` everything else; neither `Conflicting` |
| Mac → overlay path | `traceroute` hop 1 = `192.168.64.2`, then `*` | One `/16` static route; the VM is the next hop; the LB address is L2-announced by a node, so no further hop exists to show |

## Cluster and Cilium state

```
$ kubectl get nodes
poc1-control-plane    Ready    control-plane   v1.36.4
poc1-control-plane2   Ready    control-plane   v1.36.4
poc1-control-plane3   Ready    control-plane   v1.36.4
poc1-worker           Ready    <none>          v1.36.4
poc1-worker2          Ready    <none>          v1.36.4
```

```
$ cilium status
Cilium:             OK      DaemonSet cilium          5/5
Operator:           OK      Deployment cilium-operator 1/1
Envoy DaemonSet:    OK      DaemonSet cilium-envoy    5/5
Hubble Relay:       OK      Deployment hubble-relay   1/1
ClusterMesh:        disabled
```

```
$ cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading'
KubeProxyReplacement:    True   [eth0 172.18.0.4 ... (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]

(As captured on the original install. Since demo 11, `bpf.masquerade: true` is in the values files
and both lines read `Host: BPF` / `Masquerading: BPF [eth0]` — see docs/TUNING.md §1.)
```

## Demo 03 — kube-proxy replacement

Measured **before** Cilium was installed, which is what makes the claim honest:

```
$ kubectl -n kube-system get daemonset
No resources found in kube-system namespace.
```

There was never a kube-proxy DaemonSet to replace — `kubeProxyMode: none` in the kind config meant
it was never installed. Combined with `KubeProxyReplacement: True` above and a working ClusterIP
Service in demo 02, services are demonstrably being load-balanced by eBPF and by nothing else.

## Demo 01 — Hubble observability

```
$ hubble status -P
Healthcheck (via 127.0.0.1:4245): Ok
Current/Max Flows: 19,311/20,475 (94.32%)
Flows/s: 27.68
Connected Nodes: 5/5
```

Flows carry pod names, numeric security identities, verdicts and L7 detail — see demo 02 stage 3.

## Demo 02 — L3/L4 vs L7 policy

| Stage | Client | Request | Result |
|---|---|---|---|
| No policy | tiefighter | `POST /v1/request-landing` | `Ship landed` |
| No policy | xwing | `POST /v1/request-landing` | `Ship landed` |
| L3/L4 | tiefighter | `POST /v1/request-landing` | `Ship landed` |
| L3/L4 | xwing | `POST /v1/request-landing` | **timeout, curl exit 28** |
| L3/L4 | tiefighter | `PUT /v1/exhaust-port` | **`Panic: deathstar exploded`** — the gap |
| L7 | tiefighter | `POST /v1/request-landing` | `Ship landed`, HTTP 200 in 3 ms |
| L7 | tiefighter | `PUT /v1/exhaust-port` | **`Access denied`, HTTP 403 in 16.9 ms** |
| L7 | xwing | `POST /v1/request-landing` | still timeout (denied at L3) |

The headline number is the pair on the last two rows of the L7 block: **the same pod, the same
destination, the same TCP port, and two different verdicts decided by HTTP method and path.**

Secondary observation, useful as a diagnostic: an L3/L4 denial presents as a **timeout** (the SYN is
dropped), an L7 denial as an **immediate 403** (Envoy accepted, parsed, refused).

## Measured since this section was first written

Every item once listed here as "still to measure" now has its own demo and transcript:

| Demo | Result | Where |
|---|---|---|
| 04 WireGuard | encryption on the wire: zero TCP/80 packets captured across 6 HTTP requests, only UDP/51871; ~50% throughput cost (directional, single sample) | `demos/04-wireguard/` |
| 05 Gateway API | Gateway programmed from LB IPAM; policy applies to the Gateway's `ingress` identity; additive-policy hole found and closed | `demos/05-gateway-api/` |
| 06 performance | 7.6–10.0 Gbit/s intra-cluster with a 25–38% spread; netkit, bandwidth manager and BBR all unavailable on this kernel, each diagnosed to a cause | `demos/06-perf/` |
| 07 ClusterMesh | one eBPF service entry with backends in both clusters; failover 20/20; cross-cluster dependency proven both directions; throughput difference **retracted** as within noise | `demos/07-clustermesh/` |
| 08 enterprise CA | cert-manager root in poc1, identical fingerprints in both clusters, mesh certs `issuer=CN=clustermesh-root-ca`; the disk-full failure that looked like TLS | `demos/08-certmanager-ca/` |
| 09 routes + TLS | wildcard and exact certs on one Gateway, chain-verified; `HTTPRoute`, `GRPCRoute`, `TCPRoute` from one 14 MB image | `demos/09-routes/` |
| 10 flow tracing | Hubble export → OTel Collector, one flow followed end to end with 137 ms pipeline latency; events not spans | `demos/10-tracing/` |
| `cilium connectivity test` | not run — it needs ~20 min and ~1.5 GB on a laptop already at the disk and memory margin; the demos above exercise the same paths individually | — |

## Finding — the macOS host cannot reach the container network (and what fixes it)

Measured before any change:

```
$ curl -sk -o /dev/null -w '%{http_code}\n' --max-time 6 https://172.18.0.3:6443/version
000

$ netstat -rn -f inet | grep 172.18
(no output — no route exists)
```

Docker Desktop on macOS runs containers inside a Linux VM whose network the host has no route to.
**No in-cluster load balancer can fix this** — kube-vip, MetalLB and Cilium LB IPAM all allocate an
equally unreachable `172.18.x` address, because the blocker is the host↔VM boundary.

The fix is Docker Desktop 4.26+'s **`kernelForUDP`** ("kernel networking for UDP"), which creates a
host bridge and a VM-side `eth1`. This machine is on Docker Desktop **4.27.2**.

**The bridge number is not portable.** Guides name `bridge101`; here it came up as **`bridge100`**:

```
$ ifconfig -l | tr ' ' '\n' | grep -E '^bridge'
bridge0
bridge100

$ ifconfig bridge100
bridge100: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
	member: vmenet0 flags=10803<LEARNING,DISCOVER,PRIVATE,CSUM>
```

Identify it by its `vmenet` member, not by its number. The VM side:

```
$ docker run --rm --net=host --privileged busybox sh -c "ip -4 addr show eth1 | grep -o 'inet [0-9.]*'"
inet 192.168.64.2
```

Route (needs sudo, and is **not persistent** across reboots or VM restarts):

```
sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

## Finding — the two Cilium load-balancer CRDs are on different API versions

```
$ kubectl apply -f cilium/lb-ippool.yaml
Warning: cilium.io/v2alpha1 CiliumLoadBalancerIPPool is deprecated; use cilium.io/v2
```

```
$ kubectl api-resources | grep -iE 'loadbalancerippool|l2announcement'
ciliuml2announcementpolicies   l2announcement   cilium.io/v2alpha1   false   CiliumL2AnnouncementPolicy
ciliumloadbalancerippools      ippools,...      cilium.io/v2         false   CiliumLoadBalancerIPPool
```

`CiliumLoadBalancerIPPool` graduated to `v2`; `CiliumL2AnnouncementPolicy` did not. A manifest
containing both needs two different `apiVersion` values in Cilium 1.20.1.

## Finding — a multi-node kind cluster does not survive a Docker restart

The most expensive mistake of this build: Docker Desktop settings were changed **after** the
cluster was created.

| Container | Before restart | After restart |
|---|---|---|
| `poc1-control-plane` | 172.18.0.3 | **172.18.0.7** |
| `poc1-control-plane2` | 172.18.0.4 | **172.18.0.2** |
| `poc1-control-plane3` | 172.18.0.6 | **172.18.0.5** |
| `poc1-worker` | 172.18.0.5 | **172.18.0.4** |
| `poc1-worker2` | 172.18.0.2 | **172.18.0.3** |
| `poc1-external-load-balancer` | 172.18.0.7 | **172.18.0.6** |

All six containers restarted successfully. The cluster was still dead:

```
$ docker exec poc1-control-plane crictl ps -a --name kube-apiserver
3c3d04a808215  b0f70fa6ec47e  45 seconds ago  Exited  kube-apiserver  5  ...

$ crictl logs <kube-apiserver>
W grpc: addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2379", ...}
E run.go:72] "command failed" err="error creating storage factory: context deadline exceeded"
```

etcd's peer URLs and the API server certificate SANs are written at cluster-creation time around
the addresses the nodes held then. When those move, etcd cannot form a quorum and the API server
cannot reach its datastore. `kind delete cluster` and rebuild is the only practical recovery.

**Rule:** every Docker Desktop change first, in one restart, before `kind create cluster`.

**Silver lining — it re-validated the `k8sServiceHost` decision.** Across three creations of
`poc1` the external load balancer's IP was `.7`, then `.6`, then `.2`; its DNS name,
`poc1-external-load-balancer`, never changed. Passing Cilium the **name** survives every rebuild;
passing the IP would have broken on each one. That is now two independent reasons for the same
choice — the certificate SAN (which only lists the name) and rebuild stability.

## LoadBalancer addresses from the docker network

```
$ kubectl get ciliumloadbalancerippool
NAME               DISABLED   CONFLICTING   IPS AVAILABLE   AGE
kind-docker-pool   false      False         51              18s

$ kubectl -n kube-system get svc hubble-ui
NAME        TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
hubble-ui   LoadBalancer   10.11.186.239   172.18.255.200   80:32537/TCP   2m33s

$ docker run --rm --network kind curlimages/curl -s -o /dev/null \
    -w 'http_code=%{http_code} time=%{time_total}s\n' http://172.18.255.200/
http_code=200 time=0.003746s
```

Pool `172.18.255.200-250`, carved from the top of the kind docker bridge because Docker allocates
container addresses from the bottom upward — they cannot collide. Cilium's own LB IPAM and L2
announcements do the job; **MetalLB and kube-vip are not installed.**

The curl runs from a container **on the docker network** on purpose: it proves the load balancer
works independently of whether the macOS host has the Step 3.5 route. If that test returns 200 and
a browser does not, the cluster is fine and the host route is missing.

## Finding — one Cilium module is permanently DEGRADED on this kernel (benign)

`cilium-dbg status` reports:

```
Modules Health:          Stopped(0) Degraded(1) OK(94)
```

Chased down with `cilium-dbg status --all-health`:

```
  │   │   ├── job-refresh                    [OK] Next refresh in 29m59.998987992s
  │   │   └── socket-termination
  │   │       └──   [DEGRADED] service LV socket termination not supported by kernel
```

**Cause:** the Docker Desktop VM kernel (`6.6.12-linuxkit`) lacks the support Cilium needs to
forcibly terminate sockets whose service backend has gone away. It is the same class of constraint
as netkit needing ≥6.7 — a property of this kernel, not a misconfiguration.

**Impact here: none for these demos.** Service load balancing, policy, Hubble, Gateway API and
encryption all work; what is missing is that an established socket to a removed backend is not
torn down proactively, so it lingers until the application notices. Worth knowing before quoting
`Degraded(1)` at someone as a fault.

94 of 95 modules OK.

## Finding — Hubble sees traffic from the macOS host, by its bridge address

While verifying the Gateway from the laptop, Hubble recorded:

```
192.168.64.1:50186 (ingress) -> default/deathstar-...:80 (ID:70302) http-request FORWARDED (HTTP/1.1 POST http://172.18.255.200/v1/request-landing)
192.168.64.1:50186 (ingress) <- default/deathstar-...:80 (ID:70302) http-response FORWARDED (HTTP/1.1 200 13ms ...)
192.168.64.1:50187 (ingress) -> default/deathstar-...:80 (ID:83642) http-request FORWARDED (HTTP/1.1 PUT http://172.18.255.200/v1/exhaust-port)
192.168.64.1:50187 (ingress) <- default/deathstar-...:80 (ID:83642) http-response FORWARDED (HTTP/1.1 403 9ms ...)
```

`192.168.64.1` is the **macOS host's own address on `bridge100`** (SETUP Step 3.5.2). So a curl
typed on the laptop is traced by Hubble through the host route, the Gateway's Envoy and into the
pod — with the 403 verdict attributed to it. Two things follow:

- the Step 3.5 route genuinely carries host traffic into the cluster dataplane, independently
  confirmed from inside;
- Hubble's observability is not limited to pod-to-pod traffic — external clients appear with their
  real source address under the reserved `ingress` identity.

Note the latency difference in the same exchange: `200 in 13ms` measured at the host hop versus
`2ms` pod-to-pod, and `403 in 9ms` versus `0ms`. The extra milliseconds are the host→VM→Gateway
path, visible without any instrumentation.

## Finding — a reserved Gateway range, and the pin that had never worked

Reserving a pool for Gateways exposed that an earlier "fix" was not one. Both Gateways carried
`io.cilium/lb-ipam-ips` in `metadata.annotations`; **neither generated Service had it**:

```
Gateway routes-gw  metadata.annotations.io.cilium/lb-ipam-ips = 172.18.255.202
Service cilium-gateway-routes-gw annotations               = {service.cilium.io/lb-algorithm: maglev}
```

`.202` was simply the next free address. The path Cilium propagates is Gateway API's
`spec.infrastructure.annotations` (the CRD: *"annotations that SHOULD be applied to any resources
created in response to this Gateway"*; Cilium advertises `GatewayInfrastructurePropagation`).
After the change, read from the **generated** Services:

```
NS        NAME                        IP               PIN              GW-LABEL
default   cilium-gateway-sw-gateway   172.18.255.241   172.18.255.241   sw-gateway
routes    cilium-gateway-routes-gw    172.18.255.240   172.18.255.240   routes-gw
kube-system  hubble-ui                172.18.255.201   172.18.255.201   <none>
```

The split itself, applied in one `kubectl apply` so the ranges never overlapped:

```
NAME               START            STOP             CONFLICT   AVAIL
gateway-pool       172.18.255.240   172.18.255.250   False      9
kind-docker-pool   172.18.255.200   172.18.255.239   False      39
```

Selector key: `io.cilium.gateway/owning-gateway`, present on both Gateway-generated Services and
absent on `hubble-ui` (verified, not assumed). Old address `.202` confirmed dead afterwards
(`http=000`); new addresses `200 chain-verified` from the Mac; the `/16` host route needed no
change. Reference: https://docs.cilium.io/en/stable/network/lb-ipam/

## Finding — the Gateway offered no ALPN, so gRPC over TLS only worked for old clients

The demo app gained a native `-mode client` (grpc-go 1.76) so a junior can test all three routes
without Docker. Its first run against the Gateway failed exactly one check:

```
  PASS  h2c  grpc.poc.local:80   SERVING
  FAIL  TLS  grpc.poc.local:443  … missing selected ALPN property …
```

while `grpcurl` v1.9.3 had returned `SERVING` on the same listener in Part 5. Measured cause:
`openssl s_client -alpn h2,http/1.1` → `No ALPN negotiated` on every SNI; the Gateway's
`DownstreamTlsContext` carried no `alpnProtocols`. grpc-go enforces ALPN since 1.67; with
`GRPC_ENFORCE_ALPN_ENABLED=false` the same client passed, isolating the cause to ALPN alone.

Fix: `gatewayAPI.enableAlpn=true` **plus** `rollout restart deploy/cilium-operator` — the helm
upgrade only rewrote `cilium-config`, the operator pod (started 15:53) never restarted and reads
the flag at startup; 60 s of polling saw no change until the restart. After it: `alpnProtocols:
[h2,http/1.1]` in the CiliumEnvoyConfig, `ALPN protocol: h2` on all three SNIs, native client
**0 failures**, and the curl/grpcurl/nc proof (`scripts/check-routes.sh`) still 0 failures.
Transcript: `demos/09-routes/output/client-check.txt`. Gotcha #33.

## Finding — kube-proxy vs Cilium, measured on one machine (demo 11)

A control cluster (`poc3`: kindnet + kube-proxy iptables, same v1.36.4, own docker network) and
`scripts/forensic.sh` on both. The numbers the slide gets right: at 1,000 Services kube-proxy
holds **11,078** iptables rules per node, Cilium **48** (5,110 eBPF map entries); Service
programming latency 1.3–1.7 s vs 0.2–0.9 s and scale-flat; kernel conntrack under churn 38,621 vs
~110. The numbers the slide leaves out: the **default** Cilium install (tunnel/VXLAN,
`Host Routing: Legacy`, iptables masquerade, Hubble + export on) measured **6.8 vs 16.8 Gbit/s**
and **1,197 vs 8,926 qps** of connection churn. Isolated one change at a time: Hubble's per-flow
processing was the entire churn penalty (`EVENTS LOST: OBSERVER_EVENTS_QUEUE`; 8,929–9,450 qps
with it off, agent CPU 120 % → 10 %); `bpf.masquerade=true` turned host routing to BPF (9.1 →
10.2 Gbit/s); native routing removed VXLAN (15.1 Gbit/s). Best config vs kube-proxy: 15.1 vs 16.8
Gbit/s (spread 19 %), 7.8 k vs 8.9 k qps — parity within noise on a cluster paying ≈2.8 cores of
control-plane and proxy tax (VM load 13–18 vs 7) that the control does not. poc1 restored from a
values snapshot and re-verified. Full tables and the corrections kept in place:
`demos/11-kube-proxy-vs-cilium/README.md`, `output/transcript.txt`. Gotchas #39–#43.

## Finding — "Cilium mTLS" is off, deprecated, and not the feature to build on

Measured on poc1: `mesh-auth-enabled=false`, no SPIRE pods, no policy with `authentication.mode`,
`encryption.enabled=false`. The 1.20.1 chart marks `authentication.mutual` *"Deprecated as of
Cilium v1.20 … removed in Cilium v1.21"* (cilium#47132, open CFP), and the chart itself notes it
*"is not full mTLS support without also enabling encryption"*. The successor is
`encryption.type=ztunnel` (beta in 1.20.1, Cilium-internal CA, HBONE), unmeasured here for
ClusterMesh, Gateway and throughput. We run the newest Cilium (chart and tag 1.20.1). Evaluation
and plan: `docs/summary/MTLS_EVALUATION.md`.

## Finding — ztunnel mTLS works, and is not our standard (demo 13)

On poc1 it cannot start: the chart sets `CILIUM_CLUSTERMESH_CONFIG` unconditionally and Cilium's
ClusterMesh object is nil only for `cluster.id 0`, so any cluster ever given an id — connected or
not — gets `ztunnel is not compatible with clustermesh` (three attempts, source-verified). On a
throwaway `cluster.id 0` cluster: HBONE on :15008 (82 packets), marker unreadable, TLS ClientHello
captured; enrollment is iptables inside the pod netns; an L4 policy dropped the allowed peer and an
L7 policy blocked everything (000/000/000); throughput 1,216 vs 4,536 Mbit/s enrolled vs not.
Verdict: WireGuard + identity policy remain the standard. Side findings on the way: the
`cilium clustermesh` CLI rewrites helm values (#46); Hubble's ring buffer is not storage (#47);
poc2's relay had crash-looped nine hours on orphaned leaf certs from Route B (#48, fixed).

## Finding — an application split across two clusters loses nothing when a cluster loses a component (demo 15)

A five-component bank (web, api, payments, accounts + Postgres/Redis on PVCs), one image, half in
each cluster over global Services. Measured: the statement call's path `api(poc1) → accounts(poc2)`
in the response body; a payment debited once across the mesh and replayed idempotently; 40
payments split 23/17 across clusters (active-active); a continuous loop with poc1's `payments`
scaled to 0 mid-run and restored — **218 requests, 0 failed** (254/0 in the first run), traffic
on poc2 within one 5-second window; `affinity: local` 20/20 local then 20/20 remote. The first
run's 40/40-to-one-cluster was the client's keep-alive pool, not Cilium (gotcha #50).
