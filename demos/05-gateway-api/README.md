# Demo 05 — Gateway API, served by Cilium

## Is this Cilium Gateway API directly? Yes — the whole path

The short answer, because it is the first thing anyone asks. **Every hop is Cilium. Nothing else is
in the request path.**

| Layer | What handles it | How to confirm |
|---|---|---|
| Gateway controller | Cilium — `io.cilium/gateway-controller`, selected by `gatewayClassName: cilium` | `kubectl get gatewayclass` |
| Data path / proxy | Cilium's per-node **Envoy** — the *same* one enforcing demo 02's L7 policy | `kubectl -n kube-system get ds cilium-envoy` |
| External address | Cilium **LB IPAM** (`CiliumLoadBalancerIPPool`) | `kubectl get ciliumloadbalancerippool` |
| Address reachability | Cilium **L2 announcements** (`CiliumL2AnnouncementPolicy`), leader-elected per service | `kubectl -n kube-system get lease \| grep l2announce` |
| Service load balancing | Cilium eBPF (`KubeProxyReplacement: True`) | demo 03 |
| Network policy on that traffic | Cilium, including on the Gateway's own `ingress` identity | Part 3 below |

**Not involved, and not installed:** kube-vip, MetalLB, nginx, traefik, haproxy, kube-proxy. See
["Are we using kube-vip?"](#are-we-using-kube-vip--no-and-here-is-the-proof) for the proof.

So the full request `curl http://172.18.255.200/v1/request-landing` → Gateway → HTTPRoute → pod is
served end to end by one dataplane, observed by one tool (Hubble), and governed by one policy
engine.

### Confirming it yourself — two commands worth running

**The proxy is a DaemonSet, one per node, on the host network.** This is the single most useful
thing to internalise about how Cilium serves a Gateway:

```bash
kubectl -n kube-system get pods -owide | grep cilium-envoy
```

```
cilium-envoy-4ht26   1/1   Running   0   9h   172.18.0.5   poc1-worker
cilium-envoy-9p6mq   1/1   Running   0   9h   172.18.0.4   poc1-worker2
cilium-envoy-r5c6d   1/1   Running   0   9h   172.18.0.7   poc1-control-plane2
cilium-envoy-v9lk2   1/1   Running   0   9h   172.18.0.3   poc1-control-plane3
cilium-envoy-w7759   1/1   Running   0   9h   172.18.0.6   poc1-control-plane
```

Read the IP column against the node column: **every pod's IP is its node's IP.** That is not a
coincidence — the DaemonSet runs with `hostNetwork: true`:

```bash
kubectl -n kube-system get ds cilium-envoy \
  -o jsonpath='hostNetwork={.spec.template.spec.hostNetwork} desired={.status.desiredNumberScheduled} ready={.status.numberReady}'
```

```
hostNetwork=true desired=5 ready=5
```

Five nodes, five Envoys, each on its node's own network namespace. **There is no separate ingress
deployment to scale, schedule or fail over** — the proxy is already everywhere, which is also why
the L2 announcement lease can move the Gateway's address to any node and still find an Envoy there.

**The pool's actual boundaries.** `kubectl get` shows a count; `describe` shows the range, which is
what you need when checking for an overlap with Docker's own allocations:

```bash
kubectl describe ciliumloadbalancerippool kind-docker-pool
```

```
Name:         kind-docker-pool
API Version:  cilium.io/v2
Kind:         CiliumLoadBalancerIPPool
Spec:
  Blocks:
    Start:   172.18.255.200
    Stop:    172.18.255.250
  Disabled:  false
```

Note `API Version: cilium.io/v2` — the graduated version, not the deprecated `v2alpha1` (see the
README's findings section). And confirm `Start`/`Stop` sit far above anything Docker will hand a
container from `172.18.0.0/16`.

## Summary context

**What Gateway API is.** The successor to Ingress. Ingress put every non-trivial behaviour behind
controller-specific annotations, so an Ingress written for nginx rarely worked on anything else.
Gateway API splits it into three resources with three different owners:

| Resource | Owned by | Says |
|---|---|---|
| `GatewayClass` | infrastructure provider | "Cilium implements Gateways" |
| `Gateway` | platform / ops team | "there is an HTTP listener on port 80" |
| `HTTPRoute` | application team | "this path goes to my Service" |

**Why it matters that *Cilium* implements it.** With `gatewayAPI.enabled=true`, Cilium programs its
per-node Envoy — **the same Envoy that enforces L7 network policy in demo 02**. There is no nginx,
traefik or haproxy deployment alongside. One dataplane does policy, service load balancing and
ingress, and one tool (Hubble) observes all three.

**Prerequisites:** `poc1` with Cilium (SETUP Steps 3–6), the LB IP pool (SETUP Step 8), the demo 02
app deployed, and — to reach it from a browser on macOS — the route from SETUP Step 3.5.

All output below is in [`output/transcript.txt`](output/transcript.txt).

> **Address changed on 2026-09-11:** `sw-gateway` moved from `172.18.255.200` to **`172.18.255.241`**
> when a dedicated Gateway pool was reserved (demo 09, Part 7b). Quoted output below shows the old
> address as captured at the time; use `scripts/hosts-entries.sh` for the live value.

---

## Part 1 — install the CRDs and enable it

Gateway API CRDs are **not** part of Kubernetes; install them first. Cilium 1.20.1 wants **v1.6.1**:

```bash
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes; do
  kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml"
done
```

`--server-side` matters: these CRDs are large enough to exceed the annotation size limit that
client-side apply uses to store its last-applied state.

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  --reuse-values --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true
kubectl -n kube-system rollout restart deployment/cilium-operator daemonset/cilium
```

**Enable ALPN in the same upgrade.** Cilium ships `gatewayAPI.enableAlpn: false`, and with it off
the HTTPS listeners negotiate no ALPN at all — HTTP/1.1 clients never notice, but **gRPC over TLS
fails for any grpc-go ≥ 1.67 client** (`missing selected ALPN property`); this build found it in
demo 09 with a native client after `grpcurl` had reported success (gotcha #33). It costs nothing
for HTTP/1.1 backends; a backend that wants HTTP/2 declares `appProtocol: kubernetes.io/h2c` on
its Service port.

**The `rollout restart` line is not optional, and not only for the agents.** Both flags are
operator-side and land in the `cilium-config` ConfigMap; the operator reads them **at startup**. A
helm upgrade that changes only the ConfigMap leaves the running operator pod untouched — and
`rollout status` reports "successfully rolled out" because nothing rolled. Without the restart, the
GatewayClass (and later ALPN) never appears.

```bash
kubectl get gatewayclass
```

```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       51s
```

`ACCEPTED: True` means Cilium has claimed the class and will reconcile Gateways that reference it.

## Part 2 — create a Gateway and a route

```bash
kubectl apply -f demos/05-gateway-api/gateway.yaml
```

```bash
kubectl get gateway sw-gateway
```

```
NAME         CLASS    ADDRESS          PROGRAMMED   AGE
sw-gateway   cilium   172.18.255.200   True         70s
```

**`PROGRAMMED: True` with a real ADDRESS** is the payoff, and it is worth understanding where that
address came from. Cilium created a Service of type LoadBalancer for the Gateway; on kind that
would normally sit `<pending>` forever. **Cilium's own LB IPAM** assigned `172.18.255.200` from the
pool in `cilium/lb-ippool.yaml`, and **L2 announcements** made it answerable on the docker bridge.
No MetalLB, no kube-vip.

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip'
```

```
NAMESPACE     NAME                        EXTERNAL-IP
default       cilium-gateway-sw-gateway   172.18.255.200
kube-system   hubble-ui                   172.18.255.201
```

## Part 3 — the failure worth keeping: policy applies to Gateways

First request through the Gateway, from the macOS host:

```bash
curl -XPOST http://172.18.255.200/v1/request-landing
```

```
upstream connect error or disconnect/reset before headers. reset reason: connection timeout
[503 in 5.006904s]
```

**Diagnose it properly.** A 503 *from Envoy* means the Gateway is healthy and answering — the
failure is the hop from the Gateway to the backend. If the Gateway were broken you would get
nothing at all. Ask Hubble who dropped it:

```bash
hubble observe --last 30 -P --verdict DROPPED | grep deathstar
```

```
10.10.3.168:60206 (ingress) <> default/deathstar-...:80 (ID:83642) Policy denied DROPPED (TCP Flags: SYN)
```

The source identity is **`(ingress)`** — Cilium's reserved identity for traffic from its
Gateway/ingress proxy. Demo 02's policy admits only `org=empire`, and Envoy is not that.

**A Gateway is not a privileged bypass.** Its Envoy is just another client of the backend, subject
to the same policy as any pod. That is a security property, not an obstacle.

```bash
kubectl apply -f demos/05-gateway-api/allow-ingress-policy.yaml
```

```bash
curl -XPOST http://172.18.255.200/v1/request-landing
```

```
Ship landed
[200 in 0.011643s from macOS]
```

## Part 4 — the vulnerability that first fix introduced

The first version of `allow-ingress-policy.yaml` allowed the `ingress` entity on TCP 80 with **no
`rules.http`**. Everything looked fine. Then:

```bash
curl -XPUT http://172.18.255.200/v1/exhaust-port
```

```
Panic: deathstar exploded
```

**Demo 02's L7 policy was still applied, and the Gateway walked straight past it.**

Cilium policies are **additive** — separate allow-lists are unioned. A new, broader L3/L4 allow for
a new source does **not** inherit the narrower L7 restriction written for a *different* source; it
grants that source the entire port. The Gateway had become a route around the exact protection
demo 02 exists to demonstrate.

The fix is to restate the L7 rules for the new source:

```yaml
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
```

```
POST /v1/request-landing : Ship landed   [200 in 0.012677s]
PUT  /v1/exhaust-port    : Access denied [403 in 0.010145s]
```

**The transferable rule: an allow-list union is only as strict as its most permissive member.** When
you widen a policy to admit a new client, restate every restriction that matters for that client.
This is the single most valuable thing in this demo — it is a mistake that looks like success.

## "Are we using kube-vip?" — no, and here is the proof

A fair question, because on bare metal or kind the reflex is to reach for MetalLB or kube-vip to
get LoadBalancer addresses. **Neither is installed here.**

```bash
kubectl get pods -A | grep -iE 'kube-vip|metallb'
```

```
none — no kube-vip, no MetalLB
```

The complete list of workloads in `kube-system`:

```bash
kubectl -n kube-system get deploy,ds --no-headers | awk '{print $1}'
```

```
deployment.apps/cilium-operator
deployment.apps/coredns
deployment.apps/hubble-relay
deployment.apps/hubble-ui
daemonset.apps/cilium
daemonset.apps/cilium-envoy
```

Note what is **absent**: no kube-vip, no MetalLB, no kube-proxy, no nginx/traefik/haproxy ingress
controller. CoreDNS and Cilium's own components are the whole cluster.

### What replaces it

Two Cilium resources do the job a load-balancer add-on would otherwise do:

| Job | Component | Resource |
|---|---|---|
| Hand out an external IP | **Cilium LB IPAM** | `CiliumLoadBalancerIPPool` |
| Make that IP answerable on the LAN | **Cilium L2 announcements** | `CiliumL2AnnouncementPolicy` |

```bash
kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy
```

```
NAME                                                  DISABLED   CONFLICTING   IPS AVAILABLE   AGE
ciliumloadbalancerippool.cilium.io/kind-docker-pool   false      False         49              8h

NAME                                                    AGE
ciliuml2announcementpolicy.cilium.io/kind-l2-announce   8h
```

The addresses are a **reserved range carved out of the docker network** —
`172.18.255.200–250`, from the top of the `kind` bridge's `172.18.0.0/16`, because Docker allocates
container addresses from the bottom upward and the two can therefore never collide.

### It really is doing leader election, like kube-vip would

L2 announcement is not a static ARP entry. One node is elected to answer for each service, via a
Kubernetes `Lease`, and election moves if that node goes away:

```bash
kubectl -n kube-system get lease | grep l2announce
```

```
cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-worker2          3m57s
cilium-l2announce-kube-system-hubble-ui               poc1-control-plane2   3m7s
```

Two services, two different announcing nodes. That is the same failover property kube-vip provides,
built into the CNI already present.

### So when *would* you want kube-vip?

Being fair to it — kube-vip solves a problem this PoC does not have: a **highly available virtual
IP for the Kubernetes API server itself**, typically on bare metal, often before any CNI is
running. That is a bootstrap-time concern and Cilium cannot help with it, because Cilium needs the
API server to start.

Here, kind already fronts the three control planes with its own load balancer container, and the
addresses we needed were for **workload** Services and a Gateway — squarely LB IPAM's job. Adding
kube-vip would mean another DaemonSet, another leader election, and another thing that can hold a
stale ARP entry, to duplicate a capability Cilium already ships.

## What to take away

| Claim | Evidence |
|---|---|
| Cilium implements Gateway API | `GatewayClass cilium ... ACCEPTED True` |
| A Gateway gets a real address with no cloud LB | `PROGRAMMED True`, `ADDRESS 172.18.255.200` from Cilium LB IPAM |
| No extra ingress controller | no nginx/traefik/haproxy deployed; the same Envoy as demo 02's L7 policy |
| Reachable from the laptop | `200 in 0.011643s` from macOS, via the Step 3.5 route |
| Policy still governs Gateway traffic | `(ingress)` identity `Policy denied DROPPED` until explicitly allowed |
| Additive policies can silently widen access | `PUT /v1/exhaust-port` succeeded until L7 rules were restated |

## Clean up

```bash
kubectl delete -f demos/05-gateway-api/allow-ingress-policy.yaml
kubectl delete -f demos/05-gateway-api/gateway.yaml
```
