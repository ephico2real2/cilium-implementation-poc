# Demo 05 — Gateway API, served by Cilium

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
  --reuse-values --set gatewayAPI.enabled=true
kubectl -n kube-system rollout restart deployment/cilium-operator daemonset/cilium
```

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
