# Demo 15 — a bank across two clusters: ClusterMesh with a real call graph, active-active, and failover

## Summary context

Demo 07 proved the mechanism (a global Service, backends in the other cluster). This demo proves
the thing people actually want to know: **can an application be split across two clusters and keep
working — including when a cluster loses a component with no warning?** So it is a small bank with
five components and two databases, one image (`bankdemo:local`, `-mode web|api|payments|accounts`,
the demo 09 pattern), deployed *deliberately* half in each cluster, and a script that proves every
claim with the response bodies themselves: every JSON reply carries `served_by: {cluster, pod}`
and embeds its upstream's reply, so one response shows the whole cross-cluster path.

## The design

| Component | Runs in | Depends on | Why there |
|---|---|---|---|
| **web** — online-banking page | poc1 ×2 | `api` (local) | the customer edge, behind the Gateway as `https://bank.poc.local` |
| **api** — aggregator | poc1 ×2 | `accounts` (**poc2**), `payments` (global) | every page load crosses the mesh |
| **payments** — card payments, idempotent | **poc1 ×1 + poc2 ×1** | `redis` (poc1), `accounts` (poc2) | the **shared service**: one name, backends in both clusters — the active-active and failover subject |
| **accounts** — checking accounts, system of record | **poc2 ×2** | `postgres` (poc2) | the truth lives in the *other* cluster; poc1 has only the Service object |
| **postgres** (1 Gi PVC) / **redis** (1 Gi PVC, AOF) | poc2 / poc1 | — | durable state on each side, `standard` StorageClass, `WaitForFirstConsumer` |

```
  browser ──https://bank.poc.local──▶ Gateway (poc1, .240)
                                          │
   poc1                                   ▼                          poc2
  ┌──────────────────────────────────────────────┐   ┌───────────────────────────────────┐
  │  web ──▶ api ──┬──────────────────────────── ┼──▶│ accounts ──▶ postgres (PVC)       │
  │                └──▶ payments (poc1) ─────────┼──▶│                                   │
  │                        │  ▲                  │   │ payments (poc2) ──┐               │
  │                        ▼  └── global Service │   │        │          └─▶ accounts    │
  │                      redis (PVC) ◀───────────┼───┼────────┘  (redis via the mesh)    │
  └──────────────────────────────────────────────┘   └───────────────────────────────────┘
        global Services (service.cilium.io/global: "true"), Service OBJECT in both clusters:
        accounts (backends poc2 only) · payments (backends both) · redis (backends poc1 only)
```

Two rules from the docs that shape it ([Global Services](https://docs.cilium.io/en/stable/network/clustermesh/global-services/),
[Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/)): a global
Service merges **endpoints**, not objects — it must be *"defined with identical name and namespace
in each cluster"* (so `10-poc2.yaml` and `20-poc1.yaml` both declare `accounts`, `payments`,
`redis`); and `service.cilium.io/affinity: local` means *"load-balance across healthy local
backends, and only use remote endpoints if and only if all of local backends are not available or
unhealthy"* — the default `none` is no preference. The shape follows
[Bank of Anthos](https://github.com/GoogleCloudPlatform/bank-of-anthos) (frontend → ledger /
balance / accounts services over Postgres), reduced to five parts.

## Part 1 — build and deploy

```bash
docker build -t bankdemo:local -f demos/15-bank/app/Containerfile demos/15-bank/app   # golang:1.25 — pgx v5.11 needs go >= 1.25
kind load docker-image bankdemo:local --name poc1 && kind load docker-image bankdemo:local --name poc2
kubectl --context kind-poc2 apply -f demos/15-bank/10-poc2.yaml      # system of record first
kubectl --context kind-poc1 apply -f demos/15-bank/20-poc1.yaml
kubectl --context kind-poc1 apply -f demos/15-bank/30-gateway.yaml   # HTTPRoute in routes + ReferenceGrant in bank (gotcha #32)
```

What poc1's Cilium then knows — `accounts` has a backend it never scheduled, `payments` has one
from each cluster:

```
ID   Frontend                  Service Type   Backend
52   10.11.12.245:80/TCP       ClusterIP      1 => 10.20.1.91:8080/TCP (active)      <- accounts: a poc2 pod
53   10.11.166.33:80/TCP       ClusterIP      1 => 10.10.4.86:8080/TCP (active)      <- payments: poc1
                                              2 => 10.20.1.66:8080/TCP (active)      <-           poc2
```

## Part 2 — the proofs (`demos/15-bank/check.sh`, recorded in `output/transcript.txt`)

**One response, the whole path** — the page's statement call answered by an `api` in poc1 whose
balance came from an `accounts` pod in poc2:

```
{"api":"poc1","accounts":"poc2","accounts_pod":"accounts-6f57c85d5c-n7298","balance_cents":247500,"payments":"poc1"}
```

**A payment, then the same idempotency key again** — money moves once, across the mesh
(`payments` in poc1 → `accounts` in poc2 → Postgres); the replay returns the stored result and the
balance is unchanged:

```
{"balance_after":246250,"payments_cluster":"poc1","debited_by":"poc2","debited_pod":"accounts-…-n7298","replay":null}
{"replay":true,"payments_cluster":"poc2"}
{"balance_cents_after_ONE_debit":246250,"answered_by":"poc2"}
```

**Active-active** — 40 payments through the global Service, which cluster answered:

```
      23 poc1
      17 poc2
```

**Failover A — sudden downtime, default affinity.** Continuous traffic (one request every ~200 ms);
at t=15 s poc1's `payments` is scaled to **0**; at t=40 s restored:

```
  t=10s ok=34  fail=0 poc1=18 poc2=16
  t=15s ok=52  fail=0 poc1=23 poc2=29
  >>> scaling poc1 payments to 0
  t=20s ok=71  fail=0 poc1=23 poc2=48        <- every request now answered by poc2
  t=40s ok=145 fail=0 poc1=23 poc2=122
  >>> restoring poc1 payments to 1
  t=50s ok=181 fail=0 poc1=32 poc2=149       <- poc1 back in the pool
  TOTAL ok=218 fail=0 poc1=51 poc2=167
```

**Zero failed requests across the outage and the recovery**, and no client change: the Service
name and ClusterIP never moved; Cilium's eBPF service map dropped the dead backend and the remote
one carried the load. (Both runs recorded in the transcript agree: 254/0 and 218/0.)

**Failover B — `affinity: local`.** Annotate `payments` in both clusters, then:

```
  with local healthy, 20 requests:      20 poc1
  local scaled to 0,  20 requests:      20 poc2
```

Prefer-local with automatic remote failover — the pattern for latency-sensitive callers that still
need the other cluster as a backstop.

**The poc2 side works too** — a throwaway `curl` pod in poc2 pays through the global Service; that
call happened to land on the poc1 backend, which debited poc2's `accounts` and stored the record in
poc1's Redis — three mesh hops in one request:

```
{'payments_cluster': 'poc1', 'debited_by': 'poc2', 'stored_in_redis_via_mesh': True}
```

**The page, through the Gateway**, prints the path it took:

```
https://bank.poc.local -> http 200
this page: poc1/web-… → api: poc1/api-… → accounts: poc2/accounts-… · payments: poc1/payments-…
```

## Part 3 — the trap that made the first run lie (gotcha #50)

The first run reported **40/40 payments to one cluster** and, before the scale-down, 65/65 to the
other — and it was not Cilium. Go's default `http.Client` keeps connections alive, so `api` opened
**one** TCP connection to the `payments` ClusterIP and every request rode it to whichever backend
accepted the first SYN. Cilium load-balances *connections*, not requests; a pooled client sees one
backend until the connection breaks — which is exactly what the outage did (65 → 0 → poc2, and
stuck there). The demo client now opens a connection per request (`DisableKeepAlives`, with the
reason in the source). A real service keeps its pool and gets the same spread across *many*
clients; a single pooled client is the wrong instrument for measuring a load balancer.

## What to take away

| Claim | Evidence |
|---|---|
| An app can be split across clusters with no code for it — only a Service annotation | `api` in poc1 reaches `accounts` in poc2 by its ordinary DNS name |
| A shared service is active-active by default | 23 / 17 across the two clusters, 40 requests |
| A cluster losing the component costs **zero** requests | 218 ok, 0 fail through a scale-to-0 and back; 254/0 in the first run |
| Prefer-local with failover is one annotation | `affinity: local` → 20/20 local, then 20/20 remote |
| Idempotency holds across clusters | replay returns the stored record, balance unchanged |
| Connection pooling hides load balancing | 40/40 to one cluster until keep-alive was disabled |

## Clean up

```bash
kubectl --context kind-poc1 delete -f demos/15-bank/30-gateway.yaml -f demos/15-bank/20-poc1.yaml
kubectl --context kind-poc2 delete -f demos/15-bank/10-poc2.yaml        # PVCs go with the namespace
```
