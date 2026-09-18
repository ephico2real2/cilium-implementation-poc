# What demo 51 did — the walk-through

**The goal** — Enhancement 007 builds a second lab next to the Cilium one so a
reader can name every part Cilium had bundled: two kind clusters, stock
networking, Envoy Gateway, and the two software load balancers a bare-metal
team actually chooses between. Demo 50 poured the slab. Demo 51 is the first
door: kube-vip alone, no MetalLB, and the contract a team is handed — the
`EnvoyProxy` names the class and the address; the platform's load balancer
claims nothing else.

**1. Every door names its load balancer, and kube-vip claims nothing else.**
A Gateway (Envoy Gateway's front door — its own Envoy Deployment and Service,
not a share of the node's proxy) does not pick an address by existing. The
`EnvoyProxy` attached to it, created in the same file and before the Gateway,
sets `envoyService.loadBalancerClass: kube-vip.io/kube-vip-class` and pins
the IP with `kube-vip.io/loadbalancerIPs`. kube-vip runs class-only: the
DaemonSet has `lb_class_only=true`, the cloud-provider has
`KUBEVIP_ENABLE_LOADBALANCERCLASS=true`, and `--taint` is omitted so a worker
can be the ARP leader. A class-less `type: LoadBalancer` Service in `shop`
(`probe-noclass`, kept as a standing exhibit) stays `<pending>` on both
clusters — no label, no annotation, no ingress IP. That is D11, the
operator's training rule, measured while kube-vip is the only load balancer
in the building.

**2. "Configured" is not "answered on the wire."** Phase 0 taught that
`Gateway.spec.addresses` writes the Envoy Service's `externalIPs` and that
nobody announces those. Demo 51 re-ran the experiment on both clusters: a
throwaway Gateway `probe-noproxy` with only `spec.addresses` (`.245` on eg1,
`.181` on eg2) produced `externalIPs` set, `status.loadBalancer` empty, and
**0 ARP replies** from a container on `kind-eg`. Then it was deleted. The
reachable doors set *both* fields at create time — `spec.addresses` so
`status.addresses` stays honest (Envoy Gateway will not invent a different
one), and the `EnvoyProxy` annotation so kube-vip answers. Attaching the
class later cannot work: the Service field is immutable, measured in phase 0
as `may not change once set`.

**3. Two Gateways per cluster, and the shared address lives in one.** eg1's
own door is `eg1-gw` at `172.19.255.240`; eg2's is `eg2-gw` at
`172.19.255.176`. The product door `eg-vip-gw` at `172.19.255.16` is applied
to one cluster at a time (`VIP_HOME=eg1` by default). On Cilium the Gateway
could exist in both clusters and a separate L2 policy chose the announcer.
Here the annotation *is* the announcement, so two VIP Gateways would be two
ARP responders and a coin toss on every packet. `scripts/eg-vip-move.sh
kube-vip eg2` deletes the VIP Gateway, its routes and its `EnvoyProxy` from
the other cluster first, then creates them on the target. Before the move,
`arping .16` got three replies from `eg1-worker` (`6e:8c:28:fa:31:1f`);
after, three from `eg2-control-plane` (`1e:c6:bf:d8:18:97`). A `curl -m 1`
every 0.5 s during the move counted **32 samples, 23 ok, 9 fail, a gap of
10.486 s**; back to eg1 the gap was **8.976 s** (8 fails in 32). That is
the time to tear down one Envoy Deployment and roll another, not Cilium's
~40 ms lease move. Creating the VIP on eg2 did not fail with ".16 in use"
once the other side was gone.

**4. One certificate, six names, no grant.** Each cluster issues `eg-tls`
from `ClusterIssuer/eg-ca-issuer` (the lab root in `.tmp/eg-root-ca.crt`,
never committed — issue #60). The CN is the product name
`api.eg.poc.local`. The SANs are that name, the two per-cluster API names,
and three gRPC names. A wildcard was rejected in demo 40: `*.eg.poc.local`
covers one label and not `api.eg1.poc.local`. gRPC cannot share an API
hostname on one listener (demo 53 / Gateway API: if an HTTPRoute and a
GRPCRoute intersect, the implementation accepts exactly one), so gRPC has
its own names. The Gateways live in `shop` with the Secret, so Envoy
Gateway does not need a ReferenceGrant. The issued leaves share
`subject=CN=api.eg.poc.local` and `issuer=CN=eg-root-ca`, valid 2026-09-18
→ 2026-12-17; the fingerprints differ (eg1 `09:91:08:A6…`, eg2
`2C:20:A5:38…`).

**5. Two HTTPS listeners on one port, and gRPC on both h2c and TLS.** Envoy
Gateway Accepted `https:443` and `https-grpc:443` with different hostnames
on the same Gateway — the brief's stop-condition did not fire. Behind the
doors: `shopapi:local` (kind-loaded, not built; `/healthz`, `X-Served-By`
from the route filter) and `routedemo:local -mode grpc` with
`appProtocol: kubernetes.io/h2c` on port 9090. Phase 0's premise held: no
`BackendTrafficPolicy` was required. `grpcurl -plaintext -authority
grpc.eg1.poc.local 172.19.255.240:80` returned `SERVING`; the same with
`-cacert .tmp/eg-root-ca.crt` on `:443`; `list` via reflection named
Health and both reflection services. Repeated on `.176` and `.16`. The
`:80` listener also carries the 301 to https for the API names only, so
plaintext gRPC is not redirected.

**6. MetalLB is not here, and the Cilium clusters were not touched.**
`kubectl get ns metallb-system` is `NotFound` on both eg1 and eg2. poc1
and poc2 stayed `Exited (137)` on the `kind` network. `kind load` of the
two existing images worked; a second apply skipped them because `crictl
images` already showed them. `shopctl probe` WARNed —
`api.eg.poc.local` does not resolve until the operator adds the hosts
block — and every check used `--resolve` or `-authority`. `check.sh` is
39 PASS, 0 FAIL.

**The reference card — names, addresses, certificates, doors.** Read from
the live objects (`hosts-entries.sh`, `kubectl get gateway,certificate -n
shop`, `openssl x509` on `secret/eg-tls`, `scripts/eg-vip-move.sh
--status`).

*The names and their addresses.* The lab has no DNS server for
`.poc.local`; the records live in `/etc/hosts` on the machine that runs
the clients, and `hosts-entries.sh` prints them from live state:

| Name | Address | What it is | Who answers for it |
|---|---|---|---|
| `api.eg.poc.local` | `172.19.255.16` | the **product name** — cluster-agnostic | whichever cluster holds `eg-vip-gw` (eg1 today, `eg1-worker`) |
| `api.eg1.poc.local` | `172.19.255.240` | eg1's own door | eg1 (`eg1-worker`) |
| `api.eg2.poc.local` | `172.19.255.176` | eg2's own door | eg2 (`eg2-worker`) |
| `grpc.eg.poc.local` | `172.19.255.16` | gRPC on the product door | same announcer as `api.eg.poc.local` |
| `grpc.eg1.poc.local` | `172.19.255.240` | gRPC on eg1 | eg1 |
| `grpc.eg2.poc.local` | `172.19.255.176` | gRPC on eg2 | eg2 |

*The certificate.* **One `Certificate` per cluster — two in total, the same
spec in both — not one per service or per door.** Both doors in a cluster
reference the same Secret, `eg-tls`. No ReferenceGrant: Gateways are in
`shop` with the Secret.

```yaml
kind: Certificate                     # cert-manager.io/v1, namespace shop, in BOTH clusters
spec:
  secretName: eg-tls
  commonName: api.eg.poc.local         # the CN is the product name
  dnsNames:                            # six SANs — API + gRPC, product + per-cluster
    - api.eg.poc.local
    - api.eg1.poc.local
    - api.eg2.poc.local
    - grpc.eg1.poc.local
    - grpc.eg2.poc.local
    - grpc.eg.poc.local
  issuerRef: {kind: ClusterIssuer, name: eg-ca-issuer}   # → CA secret eg-root-ca, .tmp/eg-root-ca.crt
```

The issued leaves: both clusters, `subject=CN=api.eg.poc.local`,
`issuer=CN=eg-root-ca`, the six SANs, valid 2026-09-18 23:54:09Z →
2026-12-17 23:54:09Z; fingerprints eg1
`09:91:08:A6:4C:1B:51:F2:97:16:2E:FF:B9:FA:65:1D:AD:C1:B5:79:DD:F6:18:5C:14:6D:3C:96:4F:30:A2:43`,
eg2
`2C:20:A5:38:46:18:D5:63:3E:44:4B:A2:83:27:60:91:61:05:C6:06:E1:F1:79:F4:12:EA:68:32:05:6D:69:AE`.

*The doors.* Four Gateway objects exist as YAML; three are live (the VIP
is on eg1 only). Each has HTTPS `:443` for the API name, HTTPS `:443` for
the gRPC name, and HTTP `:80` for the 301 and for plaintext gRPC:

```text
                  api.eg.poc.local / grpc.eg.poc.local ─── 172.19.255.16
                              │          announced by ONE cluster (eg-vip-gw)
             ┌────────────────┴───────────┐             ┌──────────────────────────┐
             │  eg1                       │             │  eg2                     │
             │  eg-vip-gw  .16            │             │  (eg-vip-gw absent)      │
             │   https:443 api.eg.poc.local (eg-tls)    │                          │
             │   https-grpc:443 grpc.eg.poc.local       │                          │
             │   http:80  → 301 / h2c gRPC│             │                          │
             │                            │             │                          │
             │  eg1-gw     .240           │             │  eg2-gw     .176         │
             │   https:443 api.eg1.poc.local            │   https:443 api.eg2.poc.local
             │   https-grpc:443 grpc.eg1.poc.local      │   https-grpc:443 grpc.eg2.poc.local
             │   http:80  → 301 / h2c     │             │   http:80  → 301 / h2c   │
             │        │                   │             │        │                 │
             │        ▼                   │             │        ▼                 │
             │  shopapi + grpc (shop)     │             │  shopapi + grpc (shop)   │
             │  X-Served-By: eg1          │             │  X-Served-By: eg2        │
             └────────────────────────────┘             └──────────────────────────┘
   kube-vip:  eg1 range-envoy-gateway-system .240–.245; range-default .200–.205
              eg2 range-envoy-gateway-system .176–.181; range-default .136–.141
              class kube-vip.io/kube-vip-class only; class-less stays pending
```

**What the review caught.** The adversarial review has not run on this head
yet.

**What you can do with it right now.**

- `scripts/eg-vip-move.sh --status` — who holds `.16` (expect eg1,
  `eg1-worker`).
- `curl --cacert .tmp/eg-root-ca.crt --resolve api.eg1.poc.local:443:172.19.255.240 https://api.eg1.poc.local/healthz` — 200 and `X-Served-By: eg1`.
- `docker run --rm --network kind-eg fullstorydev/grpcurl:latest -plaintext -authority grpc.eg.poc.local 172.19.255.16:80 grpc.health.v1.Health/Check` — `SERVING`.
- `demos/51-eg-kube-vip/check.sh` — the 39 rows.

**Where the next demo starts.** Demo 52 installs MetalLB beside this
kube-vip, gives the same doors the other class and the MetalLB addresses,
repeats R7, and writes the side-by-side table. The contract does not
change: the `EnvoyProxy` still names the class; a class-less Service is
still nobody's.
