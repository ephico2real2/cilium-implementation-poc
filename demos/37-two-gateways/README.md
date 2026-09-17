# Demo 37 — two ways to deploy a Gateway: the platform's shared door and a team's own

## Summary context

A Cilium Gateway is a Service and a `CiliumEnvoyConfig` — no Deployment, no pods. The data plane is the per-node
`cilium-envoy` DaemonSet, shared by every Gateway and every L7 policy on the node. A team's own Gateway is
another set of listeners in the same Envoy process: its own address, listeners, certificates, ownership — not
its own CPU. kgateway, Envoy Gateway and Istio deploy a proxy per Gateway; Cilium does not.

Every HTTP application in this lab sits behind one Gateway, `routes/routes-gw`, and both ways a route may attach
to it are already measured: the Gateway's namespace owning the route with a `ReferenceGrant` for the backend, or
the app's namespace owning its route with the Gateway admitting namespaces by label (PR #17, demo 09 Part 2). That
is the platform model — one address, one wildcard certificate, one Envoy configuration, many teams. This demo is
the other model the Gateway API was designed for: **a team's own Gateway in its own namespace**, for the cases a
shared proxy serves badly. One image, two front doors, measured side by side on poc1.

- **Mode A — the platform's shared Gateway.** Namespace `team-a` (label `gateway-access: routes-gw`) owns an
  `HTTPRoute` for `shop-a.poc.local` on `routes-gw`'s `https-wildcard` listener (and the 301 on `http`). Nothing
  new on the Gateway: this is PR #17's model, exercised by a team.
- **Mode B — the team's own Gateway.** Namespace `team-b` owns `Gateway/team-b-gw` (`gatewayClassName: cilium`,
  `allowedRoutes: {namespaces: {from: Same}}`, address pinned to `172.18.255.243`), one HTTPS listener for
  `*.team-b.poc.local` with a cert-manager wildcard from `ca-issuer`, one HTTP listener carrying the 301. A `Role`
  in `team-b` granting `gateways`/`httproutes` — the platform's explicit grant, not a default (`edit` does not
  cover Gateway API objects).
- **Two doors on one app.** `team-b-gw`'s route also points at `team-a`'s Service through a `ReferenceGrant` in
  `team-a`. The JSON identifies the request; the address, the leaf, and `X-Door` identify the door.

Convention: platform pages at `<name>.poc.local` on `routes-gw`; team doors at `*.<team>.poc.local`. TLS wildcards
are single-label, so the shared `*.poc.local` leaf cannot cover a team name (measured). Gateway API wildcards are
multi-label, so attachment elsewhere is not prevented: the admission policy in `50-` is the control.

## Files

| File | What |
|---|---|
| [`00-namespaces.yaml`](00-namespaces.yaml) | `team-a` (labelled for `routes-gw`) and `team-b` (not) |
| [`10-app.yaml`](10-app.yaml) | Deployment + Service `shop` in each namespace, `routedemo:local` |
| [`20-shared-route.yaml`](20-shared-route.yaml) | team-a's serving and 301 routes on `routes-gw` |
| [`30-team-gateway.yaml`](30-team-gateway.yaml) | `team-b-gw`, pinned `.243`, `*.team-b.poc.local`, two routes |
| [`35-team-rbac.yaml`](35-team-rbac.yaml) | SA `team-b-dev`, Role `gateway-owner`, bound with `edit` |
| [`40-one-app-two-doors.yaml`](40-one-app-two-doors.yaml) | `shop-a` via `team-b-gw`, ReferenceGrant in `team-a` |
| [`50-hostname-policy.yaml`](50-hostname-policy.yaml) | ValidatingAdmissionPolicy: claim only your own zone |
| [`hosts-entries.sh`](hosts-entries.sh) | prints the `/etc/hosts` block; never writes |
| [`check.sh`](check.sh) | evidence printer for the two doors, the hijack, the policy, RBAC |

- `60-perf.yaml` — phase 3's rig: `probe` beside `shop` in each namespace (the same image, replicas, resources), the fortio
  pods `load`, `load-b` and `probe`, every pod pinned to a node and the file says why.
- `noisy-neighbour.sh` — the experiment: warm-up, then per run an idle baseline, load on the shared door, on the team door,
  on both doors, two tenants through one door, and load direct to the Service; probes concurrent inside the load window;
  every run's L2 lease holders, placement, Envoy CPU and host state recorded; JSON records under `output/perf/`.

## Run

```bash
kubectl --context kind-poc1 apply -f demos/37-two-gateways/00-namespaces.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/10-app.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/20-shared-route.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/30-team-gateway.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/35-team-rbac.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/40-one-app-two-doors.yaml
demos/37-two-gateways/hosts-entries.sh | sudo tee -a /etc/hosts
demos/37-two-gateways/check.sh
```

`50-hostname-policy.yaml` is applied by `check.sh`'s negative section and left applied. Phase 3, the load experiment:

```bash
kubectl --context kind-poc1 apply -f demos/37-two-gateways/60-perf.yaml     # two identical backends per door, three fortio pods, pinned
demos/37-two-gateways/noisy-neighbour.sh                                     # six phases × three runs (~25 min); records under output/perf/
demos/37-two-gateways/noisy-neighbour.sh 800 30s 1                           # a fixed rate instead of fortio's maximum, one run
```

## Part 1 — the two doors

Two Gateways, two addresses, one Envoy per node. `check.sh` section 1, recorded 2026-09-16
([`output/transcript-phase1.txt`](output/transcript-phase1.txt)): both doors `Programmed`, every route `Accepted`, and
`cilium-dbg envoy admin listeners` on **each** agent listing `team-b/cilium-gateway-team-b-gw/listener` beside
`routes/cilium-gateway-routes-gw/listener` — the team's door is another listener in the same per-node process, on
both nodes. The L2 leases show the two VIPs announced by two different nodes (`routes-gw` by the control plane,
`team-b-gw` by the worker) — which matters only to clients outside the cluster (Part 6 measured why).

```text
the two doors: addresses, Programmed, every route, the shared Envoy, the L2 leases
  routes/routes-gw: address=172.18.255.240 Programmed=True  (pinned .240)
  team-b/team-b-gw: address=172.18.255.243 Programmed=True  (pinned .243)
  routes (team-a and team-b):
team-a   shop            [shop-a.poc.local]   True   Accepted   True
team-a   shop-redirect   [shop-a.poc.local]   True   Accepted   True
team-b   shop                [shop.team-b.poc.local]     True   Accepted   True
team-b   shop-a-via-team-b   [shop-a.team-b.poc.local]   True   Accepted   True
team-b   shop-redirect       [*.team-b.poc.local]        True   Accepted   True
  cilium-dbg envoy admin listeners on each agent, grep cilium-gateway (the shared Envoy)
  poc1-control-plane (cilium-hzpkv):
    default/cilium-gateway-sw-gateway/listener::127.0.0.1:19308
    routes/cilium-gateway-routes-gw/listener::127.0.0.1:14386
    team-b/cilium-gateway-team-b-gw/listener::127.0.0.1:11806
  poc1-worker (cilium-tbcch):
    default/cilium-gateway-sw-gateway/listener::127.0.0.1:15333
    routes/cilium-gateway-routes-gw/listener::127.0.0.1:12589
    team-b/cilium-gateway-team-b-gw/listener::127.0.0.1:12285
  L2 lease holders:
    cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-control-plane                                                              14h
    cilium-l2announce-kube-system-hubble-ui               poc1-control-plane                                                              14h
    cilium-l2announce-routes-cilium-gateway-routes-gw     poc1-control-plane                                                              13h
    cilium-l2announce-team-b-cilium-gateway-team-b-gw     poc1-worker                                                                     52s
```

## Part 2 — the certificates

One root, two leaves: `routes-gw` presents `DNS:*.poc.local`, `team-b-gw` presents `DNS:*.team-b.poc.local`, both
`issuer=CN=clustermesh-root-ca`. cert-manager issued the team's wildcard from the listener hostname and the annotation
alone; Cilium copied it into `cilium-secrets` under a hashed name (`cilium-sync-secret-<sha256>` — match by content,
not by name).

```text
the certificates: issuer + SAN from the handshake, verified against .tmp/root-ca.crt
  shop-a.poc.local @172.18.255.240: issuer=CN=clustermesh-root-ca X509v3 Subject Alternative Name: critical     DNS:*.poc.local 
  shop.team-b.poc.local @172.18.255.243: issuer=CN=clustermesh-root-ca X509v3 Subject Alternative Name: critical     DNS:*.team-b.poc.local 
```

## Part 3 — the answers

The response says which door: `X-Door: routes-gw` at `.240`, `X-Door: team-b-gw` at `.243`; the JSON's `app` says which
backend — and `shop-a.team-b.poc.local` answers `X-Door: team-b-gw app=shop-a`, one backend behind both doors through the
`ReferenceGrant`. Every `http://` name 301s to `https://`. (The first run of `check.sh` caught the team door's redirect
route naming one host instead of the zone — `http://shop-a.team-b.poc.local` was a 404 — fixed to `*.team-b.poc.local`.)

```text
the answers: X-Door and the JSON's app; the http:// 301 for each
  https://shop-a.poc.local @172.18.255.240: HTTP 200 X-Door=routes-gw app=shop-a
  https://shop.team-b.poc.local @172.18.255.243: HTTP 200 X-Door=team-b-gw app=shop-b
  https://shop-a.team-b.poc.local @172.18.255.243: HTTP 200 X-Door=team-b-gw app=shop-a
  http://shop-a.poc.local @172.18.255.240: HTTP 301 Location=https://shop-a.poc.local:443/  (want 301 to https)
  http://shop.team-b.poc.local @172.18.255.243: HTTP 301 Location=https://shop.team-b.poc.local:443/  (want 301 to https)
  http://shop-a.team-b.poc.local @172.18.255.243: HTTP 301 Location=https://shop-a.team-b.poc.local:443/  (want 301 to https)
```

## Part 4 — the negatives

The boundary from both directions, then the hijack a shared Gateway permits, then its control:

- an unlabelled namespace on `routes-gw` and a foreign namespace on `team-b-gw`: `Accepted=False NotAllowedByListeners`;
- **the flat hijack** — `team-a` claims `shop-b.poc.local` on `routes-gw`: attached, and *served with a valid
  `*.poc.local` certificate* at `.240`. Naming cannot stop this; a shared Gateway needs a hostname policy;
- **the zoned name** — `team-a` claims `shop.team-b.poc.local` on `routes-gw`: attached (Gateway API wildcards are
  multi-label), but at `.240` every honest client fails TLS (`no alternative certificate subject name matches`,
  `ssl_verify_result=1`) — TLS wildcards are single-label — while `.243` answers with the team's own leaf. The team's
  zone is the second wall;
- **the control** — `50-hostname-policy.yaml`, a `ValidatingAdmissionPolicy` binding to the platform door's tenant
  namespaces (not `routes`, the owner's, where demo 09's `exact.example.test` lives): the zoned hijack is refused at
  admission, naming the hostname.

```text
the negatives: attachment, the flat hijack, the zoned name, then the admission policy
  -- team-b route on routes-gw (unlabelled namespace; want Accepted reason NotAllowedByListeners)
  team-b/demo37-tb-on-rgw: Accepted=False reason=NotAllowedByListeners ResolvedRefs=True  HTTPRoute is not allowed to attach to this Gateway due to namespace restrictions
  -- team-a route on team-b-gw (from: Same; want refused)
The httproutes "demo37-ta-on-tbgw" is invalid: : ValidatingAdmissionPolicy 'httproute-own-zone' with binding 'httproute-own-zone' denied request: hostname probe-ta.team-b.poc.local is not this namespace's zone
  team-a/demo37-ta-on-tbgw: Accepted=? reason=? ResolvedRefs=?  
  -- team-a claims shop-b.poc.local on routes-gw (flat-name hijack: naming cannot stop this)
  team-a/demo37-hijack-flat: Accepted=True reason=Accepted ResolvedRefs=True  Accepted HTTPRoute
  https://shop-b.poc.local @172.18.255.240: HTTP 200 X-Door=routes-gw app=shop-a
  (the hijack, served with a valid *.poc.local certificate at routes-gw)
  -- team-a claims shop.team-b.poc.local on routes-gw (zoned; attaches, TLS at .240 fails, .243 answers)
  team-a/demo37-hijack-zoned: Accepted=True reason=Accepted ResolvedRefs=True  Accepted HTTPRoute
  shop.team-b.poc.local @172.18.255.240: curl: (60) SSL: no alternative certificate subject name matches target host name 'shop.team-b.poc.local'
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.
ssl_verify_result=1 http=000  (the *.poc.local leaf does not cover a team name)
  https://shop.team-b.poc.local @172.18.255.243: HTTP 200 X-Door=team-b-gw app=shop-b
  -- admission policy applied; re-try the zoned hijack (want refusal naming the hostname)
  admission: The httproutes "demo37-hijack-zoned" is invalid: : ValidatingAdmissionPolicy 'httproute-own-zone' with binding 'httproute-own-zone' denied request: hostname shop.team-b.poc.local is not this namespace's zone
  ValidatingAdmissionPolicy httproute-own-zone left applied
```

## Part 5 — RBAC

"The team owns its Gateway" is a Role the platform grants, not a default: the built-in `edit` ClusterRole does not
cover `gateway.networking.k8s.io` and the Gateway API CRDs ship no aggregated role. Measured: `edit` alone →
`create gateways` / `httproutes` **no**; with `35-team-rbac.yaml`'s `gateway-owner` Role → yes in `team-b`, still no in
`routes`.

```text
RBAC: the platform's Role vs edit-only
  --as=system:serviceaccount:team-b:team-b-dev create gateways in team-b: yes
  --as=system:serviceaccount:team-b:team-b-dev create httproutes in team-b: yes
  --as=system:serviceaccount:team-b:team-b-dev create gateways in routes: no
  --as=system:serviceaccount:team-b:team-b-dev create httproutes in routes: no
  throwaway RoleBinding team-b-edit-only → ClusterRole edit (no gateway-owner):
  --as=system:serviceaccount:team-b:team-b-edit-only create gateways in team-b: no
  --as=system:serviceaccount:team-b:team-b-edit-only create httproutes in team-b: no
  throwaway team-b-edit-only deleted
```

## Part 6 — the noisy neighbour, measured: does a team's own Gateway isolate it?

### The claim under test, and the fact it is read against

Enhancement 005's plan states the fact first: on Cilium 1.20 a Gateway is a Service, a `CiliumEnvoyConfig` and a set of
listeners **inside the per-node `cilium-envoy` process shared by every Gateway on that node** — not a proxy of its own
(kgateway, Envoy Gateway and Istio deploy one per Gateway). Part 1 showed `team-b-gw`'s listener beside `routes-gw`'s in
both nodes' Envoys. So the question is not "does a second Gateway isolate" in the abstract, but *what a second door on
Cilium does and does not buy under a neighbour's load* — measured, with the confounders the review named recorded in
every run.

### Method

[`60-perf.yaml`](60-perf.yaml) and [`noisy-neighbour.sh`](noisy-neighbour.sh). Two **identical** backends per door
(`shop`, `probe` — the same image, replicas and resources; the review refuted probing a different application as a
sibling); fortio 1.75.3 as the generator — `-nocatchup -uniform` on every run so the generator never "catches up"
after a slow spell (the coordinated-omission bias that flatters tail latency;
[fortio README](https://github.com/fortio/fortio/blob/master/README.md), [FAQ](https://github.com/fortio/fortio/wiki/FAQ)),
`-qps 0` = fortio's maximum rate with 64 connections for the loads, a **separate low-rate probe** (20 qps, 4
connections) on its own pod for latency under load ([latency-under-load tests](https://docs.thousandeyes.com/product-documentation/connected-devices/connected-devices-tests/network/latency-under-load-tests));
`-resolve` pins each hostname to its door's VIP so SNI and `Host` are the real names; the CA is demo 36's
`enterprise-root` ConfigMap. A 10 s warm-up is excluded from every number; each run takes its own idle baseline and
every probe is read as the change from it; three runs per configuration. Recorded with every run: the L2 lease holder
of each VIP, pod placement, `cilium-envoy` CPU per node sampled **mid-load** over a 2 m window (the hub scrapes every
30 s), and the **host's** state — the whole experiment ran with CRC beside the Docker VM, the Mac at 31–35 GB in the
compressor and 3.4–3.8 GB of swap ([`output/perf/`](output/perf/), one JSON line per probe and per load). The warning
the sources give — *a generator's measuring thread that waits in the run queue records that wait as target latency,
depending on who else was scheduled on that node, recorded nowhere in the report*
([PandaStack](https://www.pandastack.ai/blog/microvm-load-testing-fleet-isolation/)) — is why those columns exist.

### Two rig faults, found by the numbers and kept in the record

1. **Clients on different Envoys** (`saturating-split-envoys.txt`). The first rig put the load pod on the worker and
   the probe pod on the control plane. Mid-load, the worker's Envoy ran at 0.3–0.85 cores and the control plane's at
   **0.01**: an in-cluster client's connection to a Gateway's LoadBalancer IP is translated on the *client's* node
   and served by that node's own Envoy — the L2 lease holder only answers ARP for clients outside the cluster. Load
   and probe had never shared a process; the flat probes measured nothing about door isolation. Fix: both fortio pods
   on the worker (one Envoy), all four upstreams on the control plane (the loaded app and the probed apps share a node
   in every phase, and the direct-to-Service control separates the node's contention from the door's).
2. **Probes outside the load window** (`saturating-one-envoy-sequential-probes.txt`). The probes ran one after another,
   30 s each, against a 30 s load: the second probe measured the quiet after it. The reading "the team door never
   degrades" was retracted; the probes now run concurrently inside a load that outlives them by 6 s. What that run still
   showed (its first probe *was* under load): a probe on the platform door tripled (p50 0.8 → 2.1–2.8 ms) whether the
   26k qps went through **its** door or the **team's**.

The 800 qps run before both (`light-800qps.txt`) is a third data point: at that rate nothing on this rig is contended —
every probe within ±0.1 ms of its baseline, on either door.

### The result (one Envoy, probes concurrent — `output/perf/20260917T1350Z`, CRC stopped; the CRC-running run beside it)

The probes, read as change from the idle baseline (three runs each):

| load (≈24k qps, 64 conns) on… | `probe-a` via **routes-gw** | `probe-b` via **team-b-gw** | probe direct to the Service |
|---|---|---|---|
| — (idle baseline) | p50 0.69 / 0.70 / 0.72 · p99 1.9 / 1.8 / 1.9 | p50 0.67 / 0.71 / 0.73 · p99 1.9 / 1.6 / 1.8 | p50 0.5–0.56 · p99 0.8–1.0 |
| **the shared door** (team-a's load) | p50 **3.5 / 3.1 / 3.6** · p99 12.0 / 10.2 / 12.7 | p50 **3.7 / 3.6 / 3.2** · p99 16.0 / 12.7 / 11.0 | p50 0.56 · p99 2.5–3.0 |
| **the team door** (team-b's load) | p50 **3.1 / 2.6 / 3.0** · p99 11.5 / 10.0 / 12.9 | p50 **3.3 / 3.2 / 3.5** · p99 14.0 / 12.7 / 12.4 | — |
| **both doors at once** (A on routes-gw, B on team-b-gw) | p50 **7.2 / 6.2 / 7.0** · p99 23 / 17 / 18 | p50 **6.6 / 7.5 / 6.9** · p99 19 / 20 / 18 | — |
| **one door, two tenants** (B's load + A's traffic through `team-b-gw`) | p50 **6.3 / 7.8 / 6.0** · p99 19 / 21 / 16 | p50 **6.9 / 6.0 / 6.8** · p99 19 / 17 / 19 | — |
| the Service directly (~117k qps, no Envoy) | p50 1.0 / 1.1 / 1.2 · p99 4.8 / 4.8 / 6.0 | p50 0.9 / 0.8 / 0.9 · p99 4.8 / 4.0 / 5.7 | — |

The loads' own numbers — the tenant's view:

| | tenant A alone (routes-gw) | tenant B alone (team-b-gw) | **both, two doors** | **both, one door** (team-b-gw) |
|---|---|---|---|---|
| A's throughput | 23.9k / 24.8k / 24.7k qps · p50 2.2 · p99 9.3–9.8 | — | **11.4k / 11.7k / 11.2k** · p50 5.0 · p99 16 | **11.4k / 12.0k / 11.1k** (via `shop-a.team-b.poc.local`) · p50 5.0 · p99 16 |
| B's throughput | — | 24.0k / 24.5k / 24.5k · p50 2.2 · p99 9.5–9.9 | **11.5k / 11.3k / 11.5k** · p50 5.0 · p99 16 | **11.9k / 11.0k / 11.5k** · p50 5.0 · p99 16 |
| `cilium-envoy` CPU, worker, mid-load | 0.9–1.3 cores | 0.8–1.8 | **2.5–2.6** | **2.4–2.6** |
| errors | 0 | 0 | 0 | 0 |

The same experiment the day before **with CRC running beside the Docker VM** (`20260916T1530Z`, the Mac at 32 GB in the
compressor and 3.4 GB of swap): the same shape at every step, with wider tails — baselines p99 3–5 ms instead of 1.9,
the both-doors probes p99 30–60 ms instead of 17–23, the loads 22–25k qps instead of 24–25k. The host is part of the
number; that is why every run's context line records it.

### What it says

- **Independence: none.** A 20 qps probe on the team's door slows by the same ×4–5 at p50 (0.8 → 3–4 ms) and to
  15–30 ms at p99 whether the neighbour's 22k qps go through *its* door or the *platform's* — indistinguishable from the
  probe on the loaded door itself. Two Gateways, one Envoy: the process is what a probe waits in.
- **Fairness: exact, and the door does not matter.** Two tenants loading at once get **half each** — ~11.5k qps
  apiece against ~24.5k alone, the same ~23k total, split to within a few hundred qps — and the split is **the same
  whether they come through two Gateways or one** (`team-a`'s traffic through `team-b`'s door beside `team-b`'s own:
  11.4k / 11.9k). Each tenant's p50 doubles, neither is starved. The ceiling is the one Envoy at ~2.5 cores on the
  worker; the node is not the limit (the same pod takes ~117k qps directly at p99 2.4 ms).
- **Where the cost sits.** The direct-load control adds ~0.5 ms to a probe at four times the request rate; the Envoy
  load adds ~2.5 ms at a quarter of it — the price is in the shared proxy's path, not the upstream or the node.
- **Stability.** Across every run of the two days, roughly 45 million requests through the Gateways and 0 errors;
  the loaded traffic's own p99 stayed at 9–10 ms at 24–25k qps through a proxy at 1–2 cores, and 16 ms with two
  tenants at its ceiling. The shared data plane is
  the *solid* part of the story — the platform gains nothing by isolating tenants from it for performance, because it
  did not falter under a deliberately noisy one.
- **The one place a second door does separate, and why it is an accident:** clients *outside* the cluster are served
  by the Envoy on the node that holds the VIP's L2 lease, and the two VIPs here are announced by two different nodes
  (`routes-gw` by the control plane, `team-b-gw` by the worker — Part 1). An external noisy neighbour on `.240` would
  land on a different process from an external client of `.243` — today. A lease election moves it. Separation by lease
  placement is not a design; a **node pool of its own** is (a Gateway whose backends and clients live on nodes no other
  tenant uses makes the per-node Envoy effectively dedicated), and so is a second cluster.

So what a team's Gateway buys on Cilium is address, zone and certificate, ownership and RBAC, and the blast radius of
*configuration* (Parts 1–5); what it does not buy is a proxy of its own — and the proxy it shares carried two tenants
at the same time, fairly, without a failed request.

### Gotcha, found on the dashboards during the runs

The *Hubble L7 HTTP Metrics by Workload* dashboard showed **No data** for `team-a` and `team-b` while Prometheus held
3,000–5,600 req/s for them: `hubble_http_requests_total` for the Gateway's traffic carries `destination_namespace` and
`destination` (the `destinationContext` name, `shop`) but **`destination_workload` only when the backend pod is local to
the node whose Envoy reported the flow** — the same metric exists in both shapes, and the one with the label sat at 0
once the upstreams were pinned to the other node. Cilium added workload metadata to the ipcache for exactly this
([cilium#27974](https://github.com/cilium/cilium/pull/27974)); on 1.20.1 with Gateway traffic it is still empty for a
remote backend. The dashboard's panels filter on the empty label. To address: the lab's copy of the dashboard reads
`destination` with `destination_workload` as the refinement (one query change), and an upstream report with the two
series as its repro. Envoy's own per-cluster metrics work per door either way — `envoy_cluster_upstream_rq_time` p99
≈ 9.0 ms on `routes-gw/team-a_shop` and 9.1 ms on `team-b-gw/team-b_shop` mid-load, `listener-secure` at 74 active
connections, the same figures on both doors.
