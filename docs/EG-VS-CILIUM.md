# Envoy Gateway and Cilium, side by side

Three stacks put a service address on a Kubernetes cluster and route HTTP and
gRPC through it. This is what each one actually did in this lab, one column
per stack, every number from a recorded transcript.

| | **Cilium** | **Envoy Gateway + kube-vip** | **Envoy Gateway + MetalLB** |
|---|---|---|---|
| demos | [40](../demos/40-shop-mesh-phase0/), [41](../demos/41-shop-mesh-phase1/), [53](../demos/53-grpc-parity/) | [51](../demos/51-eg-kube-vip/), [54](../demos/54-eg-poc1-kube-vip/), [56](../demos/56-kube-vip-bgp/) | [52](../demos/52-eg-poc2-metallb/) |
| clusters | `poc1`, `poc2` (Cilium, kube-proxy-free) | `eg1`/`eg2`, `eg-poc1` (kindnet + kube-proxy iptables) | `eg-poc2` (same) |

## The objects

| | Cilium | kube-vip | MetalLB |
|---|---|---|---|
| the data plane | Cilium's own Envoy, one per node | an `EnvoyProxy` Deployment per Gateway | the same |
| the address pool | `CiliumLoadBalancerIPPool` | a `kubevip` ConfigMap, ranges per namespace | `IPAddressPool` |
| who announces | `CiliumL2AnnouncementPolicy` | the kube-vip DaemonSet | `L2Advertisement` |
| the Gateway's proxy | shared — the cluster's Envoy | **per Gateway** (`infrastructure.parametersRef` → `EnvoyProxy`) | per Gateway |
| objects to place one door — the **installer** not counted, equally for all three (Cilium's agent and operator; kube-vip's DaemonSet, cloud-provider and RBAC; MetalLB's controller and speaker) | 3 (pool, announcement, Gateway) | 3 (ConfigMap, `EnvoyProxy`, Gateway) | 4 (`IPAddressPool`, `L2Advertisement`, `EnvoyProxy`, Gateway) |

Cilium's pool **selects** the Gateway (`selector: owning-gateway In [shop-vip-gw]`),
so the address follows the object. The other two hand the address to the
Service the Gateway generates, which is why they need the `EnvoyProxy` in
between.

## Where the address is set, and what a static one costs

This is the sharpest difference, and it cost a phase-0 experiment to find
([`EG-PHASE0.md` R0.5](EG-PHASE0.md), repeated as R7 in demo 51):

| | Cilium | kube-vip | MetalLB |
|---|---|---|---|
| `Gateway.spec.addresses` alone | the address is taken **and announced** | `status.addresses` shows it, the Service gets `externalIPs`, **`arping` gets no reply** | the same — unannounced |
| what actually announces it | the pool's selector matching the Gateway | `envoyService.loadBalancerIP` + `loadBalancerClass` on the `EnvoyProxy` | `metallb.io/loadBalancerIPs` on the `EnvoyProxy` |
| objects the address is named in | 1 | 2 | 2 |

So on Envoy Gateway a static address is **silently inert** if you only set it
where the Gateway API says to. Demo 51 records the failure and the fix as two
steps. Worse, attaching an `EnvoyProxy` to an *existing* Gateway does not take
— the Gateway has to be recreated with it (`EG-PHASE0.md` R0.5 step 2b).

**`loadBalancerClass` is mandatory in every demo here** (D11), and both load
balancers run class-only — kube-vip `--lbClassOnly`, MetalLB `--lb-class`, and
the cloud-provider's `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`. A class-less
`type: LoadBalancer` Service is then claimed by neither and stays `<pending>`
for ever: demo 51 keeps that as an exhibit (`15-probe-noclass.yaml`, check row
`$c probe-noclass stays pending`). Without the cloud-provider flag it is
claimed anyway — measured in `EG-PHASE0.md` R0.4 *"First measurement
(cloud-provider with no class filter)"*.

## Failover — and why two of these numbers must not be compared

| | measured | what was actually timed |
|---|---|---|
| **Cilium L2** | **~40 ms** | the lease moving `poc1 → poc2` (agent logs; demo 40 RECAP) |
| **kube-vip** | **9.368 s** and **9.377 s** (earlier runs 10.486 s, 8.976 s) | a client probe failing from first loss to recovery, across a Gateway **deleted here and created there** (demo 51 RECAP) |
| **MetalLB** | not measured | demo 52 is one cluster; there is no VIP to move |

**These two numbers answer different questions.** Demo 51's own RECAP says so:
*"the probe gap is the new Envoy pod turning Ready"* — kube-vip elects among
the nodes **with a ready LOCAL endpoint** (`externalTrafficPolicy: Local`),
and its log window with no announcer is 10.837 s / 10.909 s, which is the time
Kubernetes took to start the Deployment. Cilium's ~40 ms is a lease changing
hands between agents that are already running. **This lab has never timed
kube-vip's election on its own**; that, against Cilium's lease, would be the
fair comparison.

The honest summary: **a shared Envoy Gateway VIP moves as fast as a new Envoy
pod becomes Ready.** That is a property of per-Gateway proxies, not of
kube-vip, and nothing here measures kube-vip itself.

## gRPC

All three carry gRPC, and the route is load-balancer-independent — which is
itself the finding.

| | rows in the recorded check | of them, gRPC | what was proved |
|---|---|---|---|
| Cilium (53) | 11 | 9 | poc1 `h2c` and TLS `SERVING`, reflection; poc2's first `GRPCRoute` on `shop-gw`, both listeners |
| kube-vip (51) | 39 | 6 | `SERVING` plaintext on `:80` and TLS on `:443`, per door and on the shared VIP |
| MetalLB (52) | 21 | 10 | the full matrix — `ListOrders v1`, `GetOrder v2`, `WatchOrders`, `NotFound`, `Unimplemented`, `DeadlineExceeded`, an unrouted service, TLS |

A `GRPCRoute` behaves the same behind all three. The differences above are in
how much each demo chose to measure, not in what the stacks can do.

## Network policy

| | Cilium | kube-vip | MetalLB |
|---|---|---|---|
| `CiliumNetworkPolicy` | **7 per cluster** (demo 41: `api-gateway`, `backend`, `catalog`, `payment-gateway`, `orders`, `reviews`, `merchant`) plus **5** `default-deny-ingress`, one per namespace | none | none |
| why | Cilium is the CNI; identity-based policy is the same object that runs the door | kindnet — no network policy engine installed | kindnet |

This is not a fair fight and should not be read as one. The Envoy Gateway labs
run on **kindnet + kube-proxy** *on purpose*, to prove the stack works without
Cilium underneath. Adding policy to them would mean adding a CNI that has it.

## What each one cannot do here

- **Cilium**: needs Cilium. Every door, pool and announcement is a Cilium CRD;
  there is no path that uses them on a stock cluster.
- **kube-vip**: the address must be named twice (Gateway and `EnvoyProxy`), and
  the `EnvoyProxy` must exist when the Gateway is created. On a kernel without
  `CONFIG_TCP_MD5SIG` its BGP mode cannot sign sessions at all — measured in
  [demo 56](../demos/56-kube-vip-bgp/) and
  [`DEMO46_DATA_PATH.md`](DEMO46_DATA_PATH.md).
- **MetalLB**: same double-naming. Not exercised across two clusters here, so
  nothing in this lab says how its VIP moves.

## Where every number came from

| claim | source |
|---|---|
| ~40 ms lease move | `demos/40-shop-mesh-phase0/RECAP.md` |
| `gap_s=9.368` / `9.377`, and `10.837 s` / `10.909 s` | `demos/51-eg-kube-vip/RECAP.md`; all four earlier gaps in `output/transcript.txt` |
| `spec.addresses` alone is unannounced | `docs/EG-PHASE0.md` R0.5; demo 51 R7 |
| a class-less Service stays `<pending>` | `docs/EG-PHASE0.md` R0.4; demo 51 `15-probe-noclass.yaml` |
| row counts | the LAST recorded `check.sh` block in each demo's `output/transcript.txt` — not a `grep` of the script, which counts mentions and not rows |
| 7 + 5 `CiliumNetworkPolicy` | `demos/41-shop-mesh-phase1/policies/<cluster>/cnp-shop-intent.yaml` and `20-default-deny-ingress.yaml`; the RECAP's `7/7 exact names` |

Nothing here is estimated. Where a number does not exist — MetalLB's failover
— the row says so rather than borrowing one.
