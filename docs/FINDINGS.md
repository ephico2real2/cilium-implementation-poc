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
