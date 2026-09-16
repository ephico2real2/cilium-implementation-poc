# Enhancement 005 — two ways to deploy a Gateway: the platform's shared Gateway and a team's own, in its namespace

Status: **plan, measured 2026-09-16** — issue [#21](https://github.com/ephico2real2/cilium-implementation-poc/issues/21); the review pass next, then demo 37.

## 1. Why, in one paragraph

Every HTTP application in this lab sits behind one Gateway, `routes/routes-gw`, and 2026-09-16 settled both ways a route
may attach to it: the Gateway's namespace owning the route with a `ReferenceGrant` for the backend, or the app's
namespace owning its route with the Gateway admitting namespaces by label (PR #17, demo 09 Part 2). That is the
platform model — one address, one wildcard certificate, one Envoy configuration, many teams. The operator's next
question is the other model the Gateway API was designed for: **a team's own Gateway in its own namespace**, for the
cases a shared proxy serves badly — a noisy neighbour whose traffic degrades everyone else on the shared listener, a
sensitive application that wants its own address, certificate and blast radius, a heavy workload with its own
listener set and upgrade cycle. Demo 37 deploys one application both ways and measures what each buys, on Cilium.

## 2. The facts the plan rests on (measured 2026-09-16 unless cited)

| Fact | Source | Consequence |
|---|---|---|
| A Cilium Gateway creates **one Service** (`cilium-gateway-<name>`, LoadBalancer) and nothing else — no Deployment, no pods | `kubectl -n routes get svc,deploy,pods -l io.cilium.gateway/owning-gateway=routes-gw` → the Service only | the data plane is not per Gateway |
| The data plane is the **per-node `cilium-envoy` DaemonSet** (2/2 on poc1), shared by every Gateway and every L7 policy on the node | `kubectl -n kube-system get ds cilium-envoy` | a second Gateway is another set of listeners in the same Envoy process: **its own address, listeners, certificates, ownership — not its own CPU**. kgateway, Envoy Gateway and Istio deploy a proxy per Gateway; Cilium does not. The noisy-neighbour measurement is therefore a real question, not a demonstration of a known answer |
| `gateway-pool` (`172.18.255.240–250`) selects Services with `io.cilium.gateway/owning-gateway` **in any namespace**; 9 of 11 addresses free (`.240` routes-gw, `.241` sw-gateway) | `CiliumLoadBalancerIPPool` status | a team's Gateway gets its address from the same reserved range, pinned with `infrastructure.annotations` as demo 09 does |
| `routes-gw`'s HTTP(S) listeners admit routes from namespaces labelled `gateway-access: routes-gw`; an unlabelled namespace's route is refused `NotAllowedByListeners`; a route with an unknown `sectionName` is `NoMatchingParent` | PR #17, demo 09 Part 2 | the shared side of the demo is already built and measured; the ownership boundary can be shown from both directions |
| cert-manager's `ClusterIssuer/ca-issuer` issues from the lab's root into any namespace; Cilium syncs a Gateway's referenced TLS Secrets into `cilium-secrets` (`gateway-api-secrets-namespace: cilium-secrets`) | `kubectl get clusterissuer`; `cilium-config` | a team Gateway's certificate is one annotation, as on routes-gw; the sync path for a non-`routes` namespace is a thing to **verify**, not assume |
| The lab's clusters on the M5 and the runner are 1 control plane + 1 worker per cluster (`clusters/ci`) | `kubectl get nodes` → 2 | Envoy runs on both nodes; a Gateway's listeners exist on every node, whatever namespace owns it |
| The demo 09 route-app (`routedemo:local`, built by `lab-images.sh`) answers HTTP, gRPC and TCP and **echoes the Host, the path, the protocol and whether TLS terminated** in every response | `demos/09-routes/app/main.go` | the same image behind both Gateways says *which* Gateway and listener answered — no new application needed |
| The Gateway API's role model: infrastructure provider → `GatewayClass`, cluster operator → `Gateway`, application developer → `Route`; a shared Gateway admits namespaces by selector; teams "with special networking needs can deploy their own dedicated Gateway in their namespace" | [API overview](https://gateway-api.sigs.k8s.io/docs/concepts/api-overview/), [Cross-namespace routing](https://gateway-api.sigs.k8s.io/guides/multiple-ns/), [kgateway: Shared Gateways](https://kgateway.dev/blog/shared-gateways/), [Teknews: considerations for a shared Gateway](https://blog.teknews.cloud/kubernetes/2025/08/20/Considerations_for_Shared_Gateway_API.html) | the two modes are the API's own, not this lab's invention |

## 3. Decision

Demo 37 is **one application, two front doors, measured side by side** on poc1:

- **Mode A — the platform's shared Gateway.** Namespace `team-a` (label `gateway-access: routes-gw`) owns an
  `HTTPRoute` for `shop-a.poc.local` on `routes-gw`'s `https-wildcard` listener (and the 301 route on `http`), backend
  the route-app. Nothing new on the Gateway: this is PR #17's model, exercised by a team.
- **Mode B — the team's own Gateway.** Namespace `team-b` owns `Gateway/team-b-gw` (`gatewayClassName: cilium`,
  `allowedRoutes: {namespaces: {from: Same}}`, address pinned to `172.18.255.242` from `gateway-pool`, one HTTPS
  listener for `shop-b.poc.local` with a cert-manager certificate from `ca-issuer`, one HTTP listener carrying the 301
  route), its own `HTTPRoute`, the same route-app image.
- **What is measured** (§4 phase 3), in the lab's own tools: ownership from both directions, the address and certificate
  boundary, the noisy-neighbour effect under load — with the Cilium data-plane fact stated up front so the numbers are
  read for what they are — and the cost of the second door.

Not chosen: a Gateway per cluster (demo 09 already has one per cluster in the mesh: `routes-gw` on poc1, the shop
platform's on poc2 in enhancement 002) and a `GatewayClass` per team (Cilium has one controller; a second class adds
nothing measurable here).

## 4. The plan

### Phase 0 — verify the two facts the design leans on (a morning)

1. **A Gateway in a non-`routes` namespace gets its certificate and its address**: apply a throwaway `Gateway` in a
   scratch namespace with the `cert-manager.io/cluster-issuer` annotation and a pinned `.250`; measure the Certificate
   `Ready`, the Secret synced into `cilium-secrets`, the Service's `EXTERNAL-IP`, `Programmed=True`. Delete it.
2. **Where a Gateway's listeners live**: `cilium-dbg envoy` / the Envoy admin `listeners` on both nodes before and
   after — the shared-Envoy fact from §2 made visible, with the listener names.

### Phase 1 — the two namespaces and the two doors (`demos/37-two-gateways/`)

- `00-namespaces.yaml` — `team-a` (labelled for `routes-gw`), `team-b` (not).
- `10-app.yaml` — the route-app Deployment + Service in each namespace (`APP_NAME=shop-a` / `shop-b`), from
  `routedemo:local`.
- `20-shared-route.yaml` — `team-a`'s serving route (`sectionName: https-wildcard`) and redirect route (`http`) on
  `routes-gw`, `shop-a.poc.local`.
- `30-team-gateway.yaml` — `team-b-gw` with its two listeners, the pinned address, the cert-manager annotation, and
  `team-b`'s two routes attached to it by `sectionName`.
- `hosts-entries.sh` — the two names (`shop-a` → `.240`, `shop-b` → `.242`), printed, never written (README's rule).
- `check.sh` — every assertion of phase 3 as a script with recorded output, the lab's idiom (`demos/*/check.sh`).

### Phase 2 — the negatives that prove the boundary

| Attempt | Expected | Why it matters |
|---|---|---|
| `team-b` attaches a route to `routes-gw` | `Accepted=False NotAllowedByListeners` | an unlabelled team cannot use the platform door |
| `team-a` attaches a route to `team-b-gw` | refused (`from: Same`) | the team door admits its own namespace only |
| `team-a`'s route claims `shop-b.poc.local` on `routes-gw` | attached, but `shop-b` resolves to `.242` — the request never reaches `routes-gw` | a hostname is claimed at the *address*, not the Gateway: two doors cannot collide on a name that is not theirs |
| the same app answers on both: `curl https://shop-a…` and `https://shop-b…` | `{"app":"shop-a","tls":true}` / `{"app":"shop-b","tls":true}`, chains verified against the one root, different leaf certificates (`subject`, `SAN`) | one root, two certificates, two addresses |

### Phase 3 — the measurements

1. **Noisy neighbour.** `fortio`/`hey` at a fixed high rate against `shop-a` through `routes-gw` (the shared door),
   while a low-rate probe measures p50/p99 latency of (a) a sibling on the shared door (the bank's `bankapi`), and (b)
   `shop-b` through the team door; then the load moved to `shop-b`, the probes repeated. Read with the Cilium fact in
   hand: both Gateways are listeners in the same per-node Envoy, so the expectation is that the team door **shares** the
   degradation; whatever the numbers say is the finding, and the write-up names what *does* isolate on Cilium (a node
   pool with `nodeSelector`-placed workloads and a Gateway whose Service uses `externalTrafficPolicy: Local`? a second
   cluster? — to be measured in the same section, not asserted).
   Metrics: `cilium-envoy` ServiceMonitor (demo 16) per node — `envoy_cluster_upstream_rq_time`,
   `envoy_listener_downstream_cx_active` by listener name; Hubble L7 flows by `destination_workload`.
2. **Ownership and blast radius.** RBAC: a `team-b` ServiceAccount with `edit` on its namespace can create/change
   `team-b-gw` and its routes but cannot touch `routes-gw` (`kubectl auth can-i`, recorded). Change: `team-b` adds a
   listener (a second hostname) — `routes-gw`'s status untouched, its `attachedRoutes` unchanged.
3. **Cost.** Two Services with two LB-IPAM addresses, N+M listeners in Envoy, the certificate count — measured; and
   what a per-Gateway-proxy implementation would have added (a Deployment per Gateway) stated from its documentation.
4. **Evidence.** Hubble UI on `team-a`/`team-b`; the verdicts dashboard; the L7 dashboard by workload; the `Gateway`
   statuses; the route-app's own JSON answers. Captured by `scripts/evidence/`, walked by `scripts/capture/` in the
   Action (a `lab-apps.sh` lab `two-gateways`, its traffic in `rounds`).

### Phase 4 — the write-up and the lab's docs

- `demos/37-two-gateways/README.md`: Summary context (the two modes, the Cilium fact first), the parts above, *What to
  take away* — "when to give a team its own Gateway on Cilium, and what you actually get".
- Demo 09 Part 2's note gains the pointer it already reserves ("the subject of demo 37"); `NETWORKING_DESIGN.md` §on the
  Gateway range: `.242` reserved for demo 37; gotchas for whatever bites (the Secret sync, the L2 announcement of a
  second Gateway address, path precedence); README's demo table row; `docs/POLICY-TEST-RESULTS.md` if any policy is
  generated for the two namespaces (cf2cnp on the route-app's flows would be a natural chapter 37).

## 5. Questions for the operator — answered 2026-09-16: "yes to all"

The route-app; fortio in-cluster; the isolating variant built in the same demo (phase 3.1's last question becomes a
part: `shop-b` on poc2 behind enhancement 002's Gateway, load on poc1 — a separate data plane, measured beside the
same-cluster team Gateway). The review pass runs on Grok (ZDR), the operator's choice.

1. **The app.** The demo 09 route-app (HTTP + gRPC + TCP, echoes host/listener/TLS) or a new one? The plan assumes the
   route-app — it already proves *which door answered*, and gRPC/TCP listeners on the team Gateway come free.
2. **Load tool.** `fortio` (a pod in the cluster, reports p50/p99 as JSON, the lab can keep the report) or `hey` from
   the Mac (simpler, but the Mac's route into the VM is then part of the measurement). The plan assumes fortio in-cluster.
3. **How far to take isolation.** Measure the noisy-neighbour effect and *name* what isolates on Cilium (§4 phase 3.1),
   or also build one isolating variant in the same demo (the second cluster is already there: `shop-b` on poc2 behind
   enhancement 002's Gateway, load on poc1 — a true separate data plane)?

## 6. Risks

- **The Secret sync for a Gateway outside `routes`** (§4 phase 0.1) — if Cilium's operator does not pick up a
  Secret in `team-b`, the listener stays `ResolvedRefs=False`; the fix is documented (`gatewayAPI.secretsNamespace.sync`),
  measured first.
- **A second L2-announced address**: `.242` on the same interface — demo 09 Part 7b measured one; two is the same
  mechanism, but `kind-l2-announce` selects `loadBalancerIPs: true` for every Service, so nothing to change — verify
  from the Mac with `arp -a` before and after.
- **The noisy-neighbour numbers on a laptop** are noisy themselves (demo 06 measured 25–38 % run-to-run); the
  measurement is repeated (three runs, the spread reported) and read as a shape, not a decimal.
- **The runner's memory**: fortio and two more route-app pods are small; the load itself is the risk on 4 vCPU — the
  Action runs the measurement at a lower rate than the M5 and reports both.
