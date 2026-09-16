# Enhancement 005 — two ways to deploy a Gateway: the platform's shared Gateway and a team's own, in its namespace

Status: **plan, measured 2026-09-16, reviewed** ([docs/REVIEW_ENH-005.md](../docs/REVIEW_ENH-005.md): five refutations accepted, each
checked on the lab) — issue [#21](https://github.com/ephico2real2/cilium-implementation-poc/issues/21); phase 0 done; phase 1 next.

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
| A Cilium Gateway creates a **Service** (`cilium-gateway-<name>`, LoadBalancer) and a **`CiliumEnvoyConfig`** of the same name — configuration, no Deployment, no pods | `kubectl -n gw-probe get svc,ciliumenvoyconfig` on the phase 0 probe → one of each; `get deploy,pods` → none | the data plane is not per Gateway |
| The data plane is the **per-node `cilium-envoy` DaemonSet** (2/2 on poc1), shared by every Gateway and every L7 policy on the node; a Gateway's listener is programmed into **every** node's Envoy | `kubectl -n kube-system get ds cilium-envoy`; phase 0: `cilium-dbg envoy admin listeners` on both agents lists `routes/cilium-gateway-routes-gw`, `default/cilium-gateway-sw-gateway` and `gw-probe/cilium-gateway-probe-gw` on **both** nodes | a second Gateway is another set of listeners in the same Envoy process: **its own address, listeners, certificates, ownership — not its own CPU**. kgateway, Envoy Gateway and Istio deploy a proxy per Gateway; Cilium does not. The noisy-neighbour measurement is therefore a real question, not a demonstration of a known answer |
| `gateway-pool` (`172.18.255.240–250`) selects Services with `io.cilium.gateway/owning-gateway` **in any namespace**; `.240` routes-gw, `.241` sw-gateway, **`.242` is claimed by enhancement 002** (the shop platform's `shop-gw`) | `CiliumLoadBalancerIPPool` status; phase 0: the probe in `gw-probe` got its pinned `.250`; `002-shop-platform-clustermesh.md` line 61 | a team's Gateway gets its address from the same range, pinned with `infrastructure.annotations`; demo 37 takes **`.243`** |
| **Every LoadBalancer Service has its own L2 lease and its own leader**; at the time of measuring, `routes-gw`'s VIP was announced by `poc1-control-plane` and the probe's by `poc1-worker` — two Gateways, two nodes, two Envoy processes, by chance | `kubectl -n kube-system get leases` (`cilium-l2announce-<ns>-<svc>` → `holderIdentity`) | the noisy-neighbour measurement must **record and control the lease holders**, or a lucky split reads as isolation |
| `routes-gw`'s HTTP(S) listeners admit routes from namespaces labelled `gateway-access: routes-gw`; an unlabelled namespace's route is refused `NotAllowedByListeners`; a route with an unknown `sectionName` is `NoMatchingParent` | PR #17, demo 09 Part 2 | the shared side of the demo is already built and measured; the ownership boundary can be shown from both directions |
| cert-manager's `ClusterIssuer/ca-issuer` issues into the Gateway's namespace; Cilium (`enable-gateway-api-secrets-sync=true`) copies the referenced Secret into `cilium-secrets` under the name **`cilium-sync-secret-<sha256>`** — a search by the original name finds nothing; match by `tls.crt` content | phase 0 in `gw-probe`: `Certificate Ready=True`, the copy's `tls.crt` byte-identical, the listener `ResolvedRefs=True`, a TLS handshake to `.250` presenting `issuer=CN=clustermesh-root-ca, SAN probe.poc.local`, Envoy's 404 for the routeless host; on delete the copy and the lease vanish | one annotation gives a team Gateway its certificate; **gotcha**: the hashed name |
| The built-in `edit` ClusterRole does **not** cover `gateway.networking.k8s.io`, and the Gateway API CRDs ship no `aggregate-to-edit` role | `kubectl auth can-i create httproutes --as=system:serviceaccount:gw-probe:probe-editor` → **no**; `gateways` → **no** | "the team owns its Gateway" is a **Role the platform grants**, not a default; the demo states it |
| **Two wildcard rules disagree.** Gateway API hostname matching is multi-label: a route for `shop.team-b.poc.local` attaches to the `*.poc.local` listener (`Accepted=True`). TLS matching is single-label (RFC 6125): the `*.poc.local` certificate's SAN does not cover `shop.team-b.poc.local` (`curl … ssl_verify=1`), while it does cover `shop-b.poc.local` (`ssl_verify=0` — served, the hijack) | measured on `routes-gw` with a throwaway route, 2026-09-16 | **each team Gateway gets its own zone and wildcard certificate, `*.<team>.poc.local`** (the operator's question): a hijack through the shared door then fails certificate validation for any honest client — a second wall; attachment still succeeds, so the admission policy stays the control |
| The lab's clusters on the M5 and the runner are 1 control plane + 1 worker per cluster (`clusters/ci`) | `kubectl get nodes` → 2 | Envoy runs on both nodes; a Gateway's listeners exist on every node, whatever namespace owns it |
| The demo 09 route-app (`routedemo:local`, built by `lab-images.sh`) answers HTTP, gRPC and TCP and **echoes the Host, the path, the protocol and whether TLS terminated** in every response | `demos/09-routes/app/main.go` | the same image behind both doors identifies the *request*; which **door** answered is proven by the address the client used, the leaf certificate presented, and a `ResponseHeaderModifier` filter on each route stamping `X-Door: routes-gw` / `X-Door: team-b-gw` — no new application needed |
| The Gateway API's role model: infrastructure provider → `GatewayClass`, cluster operator → `Gateway`, application developer → `Route`; a shared Gateway admits namespaces by selector; teams "with special networking needs can deploy their own dedicated Gateway in their namespace" | [API overview](https://gateway-api.sigs.k8s.io/docs/concepts/api-overview/), [Cross-namespace routing](https://gateway-api.sigs.k8s.io/guides/multiple-ns/), [kgateway: Shared Gateways](https://kgateway.dev/blog/shared-gateways/), [Teknews: considerations for a shared Gateway](https://blog.teknews.cloud/kubernetes/2025/08/20/Considerations_for_Shared_Gateway_API.html) | the two modes are the API's own, not this lab's invention |

## 3. Decision

Demo 37 is **one image, two front doors, measured side by side** on poc1 — one backend for the functional proof, two
identical backends for the performance one:

- **Mode A — the platform's shared Gateway.** Namespace `team-a` (label `gateway-access: routes-gw`) owns an
  `HTTPRoute` for `shop-a.poc.local` (a platform-zone name, under the shared wildcard certificate) on `routes-gw`'s `https-wildcard` listener (and the 301 route on `http`), backend
  the route-app. Nothing new on the Gateway: this is PR #17's model, exercised by a team.
- **Mode B — the team's own Gateway.** Namespace `team-b` owns `Gateway/team-b-gw` (`gatewayClassName: cilium`,
  `allowedRoutes: {namespaces: {from: Same}}`, address pinned to `172.18.255.243` from `gateway-pool` — `.242` is
  enhancement 002's — one HTTPS listener for **`*.team-b.poc.local`** with a cert-manager **wildcard** certificate from
  `ca-issuer` (the team's own zone: `shop.team-b.poc.local`, and any later name, one certificate, one DNS wildcard
  record to `.243`), one HTTP listener carrying the 301 route), its own `HTTPRoute`, the same route-app image. The
  convention the demo sets: platform pages at `<name>.poc.local` on `routes-gw`; team doors at `*.<team>.poc.local`. A `Role` in `team-b` granting
  `gateways`/`httproutes` (the platform's explicit grant, §2) bound to the team's ServiceAccount.
- **The functional "two doors on one app"**: `team-b-gw`'s route also points at `team-a`'s Service through a
  `ReferenceGrant` in `team-a` — literally one backend behind both doors, the response header saying which.
- **What is measured** (§4 phase 3), in the lab's own tools: ownership from both directions, the address and certificate
  boundary, the noisy-neighbour effect under load — with the Cilium data-plane fact stated up front so the numbers are
  read for what they are — and the cost of the second door.

Not chosen: a Gateway per cluster (demo 09 already has one per cluster in the mesh: `routes-gw` on poc1, the shop
platform's on poc2 in enhancement 002) and a `GatewayClass` per team (Cilium has one controller; a second class adds
nothing measurable here).

## 4. The plan

### Phase 0 — verify the facts the design leans on — **done 2026-09-16**, results in §2

1. A throwaway `Gateway` in `gw-probe` with the `cert-manager.io/cluster-issuer` annotation and a pinned `.250`, checked
   **in order**: the Gateway and its Service exist with `.250` → the `Certificate` `Ready` and its Secret in `gw-probe` →
   the copy in `cilium-secrets` (hashed name, `tls.crt` identical) → the **listener** `ResolvedRefs=True`,
   `Accepted=True`, `Programmed=True` (the Gateway's own `Programmed` can precede TLS) → a TLS handshake to `.250`
   presenting the leaf → deletion removes Service, `CiliumEnvoyConfig`, the synced copy, the lease and the allocation.
2. `cilium-dbg envoy admin listeners` on both agents: the probe's listener on **both** nodes beside `routes-gw`'s and
   `sw-gateway`'s; the L2 leases showing two Gateways announced from two different nodes.

### Phase 1 — the two namespaces and the two doors (`demos/37-two-gateways/`)

- `00-namespaces.yaml` — `team-a` (labelled for `routes-gw`), `team-b` (not).
- `10-app.yaml` — the route-app Deployment + Service in each namespace (`APP_NAME=shop-a` / `shop-b`), from
  `routedemo:local`.
- `20-shared-route.yaml` — `team-a`'s serving route (`sectionName: https-wildcard`) and redirect route (`http`) on
  `routes-gw`, `shop-a.poc.local`.
- `30-team-gateway.yaml` — `team-b-gw` with its two listeners, the pinned `.243`, the cert-manager annotation, and
  `team-b`'s two routes attached to it by `sectionName`; every serving route carries a `ResponseHeaderModifier`
  (`X-Door`), so a response names the door that answered.
- `35-team-rbac.yaml` — the `Role` (`gateways`, `httproutes`: get/list/watch/create/update/patch/delete — no `status`)
  and its binding for `team-b`'s ServiceAccount; `40-one-app-two-doors.yaml` — `team-b-gw`'s route to `team-a`'s Service
  with the `ReferenceGrant` in `team-a`.
- `hosts-entries.sh` — `shop-a.poc.local` → `.240`, `shop.team-b.poc.local` → `.243` (`/etc/hosts` has no wildcards; a
  real zone gets `*.team-b.poc.local`), printed, never written (README's rule).
  **Note:** `scripts/hosts-entries.sh` maps every hostname it finds on `routes-gw` to `routes-gw`'s address — the
  hijack row below shows what that means.
- `check.sh` — every assertion of phase 3 as a script with recorded output, the lab's idiom (`demos/*/check.sh`).

### Phase 2 — the negatives that prove the boundary

| Attempt | Expected | Why it matters |
|---|---|---|
| `team-b` attaches a route to `routes-gw` | `Accepted=False NotAllowedByListeners` | an unlabelled team cannot use the platform door |
| `team-a` attaches a route to `team-b-gw` | refused (`from: Same`) | the team door admits its own namespace only |
| `team-a`'s route claims a team-b name on `routes-gw` — twice: `shop-b.poc.local` (flat) and `shop.team-b.poc.local` (the team's zone) | both **attach** (Gateway API wildcards are multi-label; no hostname is reserved across Gateways). At `.240` the flat name is **served with a valid certificate** — the hijack, complete; the zoned name is served too but under the `*.poc.local` leaf, which does not cover it — every honest client fails TLS (`ssl_verify=1`, measured). `--resolve …:.243` answers from `team-b` with its own leaf either way. Then the control: a `ValidatingAdmissionPolicy` on `HTTPRoute.spec.hostnames` (a namespace may claim only its own zone) — the route refused at admission, recorded | a shared Gateway needs a hostname policy; the team's own zone and certificate are the second wall; the address is not the boundary |
| the same app answers on both: `curl https://shop-a…` and `https://shop-b…` | `X-Door: routes-gw` with the `*.poc.local` leaf at `.240`; `X-Door: team-b-gw` with the `shop-b.poc.local` leaf at `.243`; both chains to the one root; `serial`/`SAN` differ | one root, two certificates, two addresses, and the door named in the response |

### Phase 3 — the measurements

1. **Noisy neighbour — a controlled experiment, not one run.** fortio in-cluster, load and probe in **separate pods
   with fixed placement and resources**, targets addressed by `EXTERNAL-IP` + `Host`/SNI (in-cluster DNS knows no
   `*.poc.local`). The backends are **the same image, same replicas, same requests** (`shop-a`, `shop-b`; not the bank).
   Runs, each three times, order randomised, every result read as the change from that run's idle baseline:
   (0) idle baseline; (1) load on `shop-a` via `routes-gw`, probe `shop-a`; (2) probe a same-image sibling on the **same**
   door; (3) probe `shop-b` via the **team** door; (4) the control that bypasses Envoy — load and probe **direct to the
   Service**, which measures backend and node contention alone; (5) saturate the **listener**, not the app (a path that
   404s at Envoy), so Envoy is the bottleneck under test. Recorded with every run: the **L2 lease holder of each VIP**
   (`kubectl -n kube-system get leases`), pod placement, achieved RPS and errors, `cilium-envoy` process CPU per node
   and per-listener stats (`envoy_listener_downstream_cx_active`, `envoy_http_downstream_rq_time` by listener),
   node CPU throttling. One deliberate run with both VIPs announced by the **same** node and one with them split, since
   §2 measured the split happening by chance. `externalTrafficPolicy: Local` is **not** a variant: Cilium documents it
   as incompatible with L2 announcements. The finding is what the numbers show; the Cilium fact from §2 is the
   architecture they are read against, not a number they can overturn.
2. **Ownership — configuration scope, stated as such.** `edit` alone → `can-i create gateways/httproutes` = **no**
   (measured); with the platform's `Role` (phase 1) → yes in `team-b`, still no in `routes`. Change: `team-b` adds a
   listener — `routes-gw`'s status and `attachedRoutes` untouched. What this is **not**: runtime blast radius — an Envoy
   crash, resource exhaustion or a proxy upgrade is per node, shared by every Gateway; the write-up says so.
3. **Cost.** Two Services with two LB-IPAM addresses and two L2 leases, N+M listeners in every node's Envoy, two
   `CiliumEnvoyConfig`s, the certificate count — measured; per-Gateway CPU is **not measurable** on Cilium (one process);
   what a per-Gateway-proxy implementation adds (a Deployment per Gateway) is stated from its documentation, marked so.
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

The route-app; fortio in-cluster; the isolating variant built in the same demo — **as its own Gateway and its own
route-app on poc2** (enhancement 002 is an unbuilt plan and its Gateway is the shop platform's, not this app's): the
same image, replicas, TLS and load shape; the probe client **on the serving cluster**; `shop-b`'s address the poc2
Gateway's own, no global Service or mesh hop in the path. A second cluster is a second `cilium-envoy` — a separate data
plane — but on one 4-vCPU host it is not separate CPU; the runner's result is read with that said. The review pass
ran on Grok (ZDR), the operator's choice.

1. **The app.** The demo 09 route-app (HTTP + gRPC + TCP, echoes host/listener/TLS) or a new one? The plan assumes the
   route-app — with the `X-Door` header, the address and the leaf certificate it proves *which door answered*; gRPC and TCP
   are out of demo 37's scope (a TCP door needs its own listener, Service port and `TCPRoute` — demo 09 has that).
2. **Load tool.** `fortio` (a pod in the cluster, reports p50/p99 as JSON, the lab can keep the report) or `hey` from
   the Mac (simpler, but the Mac's route into the VM is then part of the measurement). The plan assumes fortio in-cluster.
3. **How far to take isolation.** Measure the noisy-neighbour effect and *name* what isolates on Cilium (§4 phase 3.1),
   or also build one isolating variant in the same demo (the second cluster is already there: `shop-b` on poc2 behind
   enhancement 002's Gateway, load on poc1 — a true separate data plane)?

## 6. Risks

- **The Secret sync for a Gateway outside `routes`** (§4 phase 0.1) — if Cilium's operator does not pick up a
  Secret in `team-b`, the listener stays `ResolvedRefs=False`; the fix is documented (`gatewayAPI.secretsNamespace.sync`),
  measured first.
- **A second L2-announced address** (`.243`): the same mechanism, but **one lease and one leader per Service** — the
  two VIPs may be announced by different nodes (measured: they were), which is the noisy-neighbour confounder of phase
  3.1. Record `cilium-l2announce-*` holders in every run; `arp -a` on the Mac shows the VM's edge, not the leader.
  `externalTrafficPolicy: Local` is incompatible with L2 announcements — not a knob here.
- **The hostname hijack is real on a shared Gateway** (phase 2, row 3): the demo shows it and its control; until the
  admission policy exists, `scripts/hosts-entries.sh` maps any hostname found on `routes-gw` to `.240`.
- **`edit` does not own Gateway API objects**: without the phase 1 `Role` the ownership claim is false; with it, the
  claim is "the platform grants the team its Gateway" — the honest form.
- **The noisy-neighbour numbers on a laptop** are noisy themselves (demo 06 measured 25–38 % run-to-run); the
  measurement is repeated (three runs, the spread reported) and read as a shape, not a decimal.
- **The runner's CPU**: both clusters, four Envoy pods, fortio and the apps share 4 vCPU — load on poc1 can degrade poc2
  with separate data planes; the Action runs at a rate below host saturation, records node throttling, and reports
  the M5's numbers beside its own.
