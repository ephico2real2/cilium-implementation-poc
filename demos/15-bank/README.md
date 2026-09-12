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
balance / accounts services over Postgres), reduced to five parts; the split-across-clusters
pattern follows AWS's [multi-cluster shared services architecture with Cilium ClusterMesh](https://aws.amazon.com/blogs/containers/a-multi-cluster-shared-services-architecture-with-amazon-eks-using-cilium-clustermesh/),
which stops at connectivity — the failover measurements here are what it does not show. All
sources: `docs/REFERENCES.md`.

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

## Part 3 — external access: the page AND the API on the Gateway, and the hosts block

`30-gateway.yaml` publishes two names on the demo 09 Gateway, both under the wildcard certificate:

| URL | Backend | Proof from the Mac (`--resolve`, chain verified against `docs/root-ca.crt`) |
|---|---|---|
| `https://bank.poc.local` | `web` | `http 200`, the page prints its path |
| `https://bankapi.poc.local` | `api` | `GET /api/balance/chk-1001 → {'owner': 'Ada Lovelace', 'balance_cents': 246250, 'api': 'poc1', 'accounts': 'poc2'}` · `POST /api/pay → {'payments': 'poc1', 'debited_by': 'poc2', 'balance_after': 245251}` · `GET /api/statement/chk-1001 → 4 payments listed` |

An external client (your laptop, a partner, a mobile app) reaches the API through the Gateway
and its request still crosses the mesh — `api` in poc1, `accounts` in poc2 — visible in the body.

**Why it is `bankapi.poc.local` and not `api.bank.poc.local`.** The first attempt used the
two-label name and failed with `curl exit 60`: the Gateway presented the `*.poc.local` certificate,
and **a wildcard matches exactly one DNS label** — `api.bank.poc.local` matches neither the
`https-wildcard` listener's `hostname: "*.poc.local"` nor the certificate's SAN. Recorded in the
transcript; gotcha #52. A deeper name needs its own listener and certificate (`*.bank.poc.local`),
which is a legitimate design — just not a free one.

**The hosts block, scoped to the bank.** `demos/15-bank/hosts-entries.sh` is a clone of
`scripts/hosts-entries.sh` that reads only the bank's two HTTPRoutes and prints its **own**
delimited block, so it can be added and removed independently of the demo 09 block:

```bash
demos/15-bank/hosts-entries.sh
```
```
# ---- cilium-kind-poc bank (generated 2026-09-12T01:24Z by demos/15-bank/hosts-entries.sh) ----
172.18.255.240  bank.poc.local bankapi.poc.local
# ---- end cilium-kind-poc bank ----
```
Add it, verify one layer at a time, then use the names — the `sudo` lines are yours to run:

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc
demos/15-bank/hosts-entries.sh                                  # review first
sudo sh -c 'demos/15-bank/hosts-entries.sh >> /etc/hosts'      # you run this
grep -c 'bankapi.poc.local' /etc/hosts                          # expect 1
dscacheutil -flushcache; sudo killall -HUP mDNSResponder        # drop the macOS resolver cache
open https://bank.poc.local
curl -s --cacert docs/root-ca.crt https://bankapi.poc.local/api/balance/chk-1001
```

Expected from the last line (your balance will differ):

```
{"account":"chk-1001","balance_cents":245251,"owner":"Ada Lovelace","served_by":{"cluster":"poc1",…},"upstream":{…"served_by":{"cluster":"poc2",…}}}
```

Remove the block later, on its own, leaving the demo 09 block untouched:

```bash
sudo sed -i '' '/---- cilium-kind-poc bank/,/---- end cilium-kind-poc bank/d' /etc/hosts
```

(`scripts/hosts-entries.sh` also lists both names now, since it reads every route on the Gateway;
use whichever block you prefer, not both.)

## Part 4 — the trap that made the first run lie (gotcha #50)

The first run reported **40/40 payments to one cluster** and, before the scale-down, 65/65 to the
other — and it was not Cilium. Go's default `http.Client` keeps connections alive, so `api` opened
**one** TCP connection to the `payments` ClusterIP and every request rode it to whichever backend
accepted the first SYN. Cilium load-balances *connections*, not requests; a pooled client sees one
backend until the connection breaks — which is exactly what the outage did (65 → 0 → poc2, and
stuck there). The demo client now opens a connection per request (`DisableKeepAlives`, with the
reason in the source). A real service keeps its pool and gets the same spread across *many*
clients; a single pooled client is the wrong instrument for measuring a load balancer.

## Part 5 — `exercise.sh`: watch it work, from outside

`demos/15-bank/exercise.sh [count] [account] [--failover]` drives the bank through the Gateway
(`https://bankapi.poc.local`, pinned with `--resolve`, so no hosts entry is needed) and prints one
line per payment: merchant, amount, HTTP code, which cluster/pod took the payment, which cluster/pod
debited the account, the balance after, and the latency. It tops the account up first (via
`/api/credit`), then a summary, then an idempotency replay. `--failover` scales poc1's `payments` to
0 at call 20 and back at call 40, so the *payments* column flips before your eyes.

```
$ demos/15-bank/exercise.sh 60 chk-1002 --failover
topping up chk-1002 by 255084 cents (balance 916 < 256000 needed for 60 calls): balance now 256000
#    merchant     cents  http   payments (cluster/pod)   debited by (cluster/pod)    balance      ms
1    books         3571  201    poc2/payments-c2mzn      poc2/accounts-7sctb          252429     211
12   books         2121  201    poc1/payments-mmq57      poc2/accounts-7sctb          234023     170
>>> poc1 payments scaled to 0 (sudden downtime)
20   coffee        1293  201    poc2/payments-c2mzn      poc2/accounts-6pzxz          221710     172
…
>>> poc1 payments restored to 1
51   fuel          1458  201    poc1/payments-r9nxj      poc2/accounts-7sctb          157315     161
summary
  calls: 60  ok: 60  declined (409, insufficient funds): 0  FAILED (infrastructure): 0  in 50 s
  payments served by : poc2=49 poc1=11
  debited by accounts: poc2=60   (accounts runs in poc2 only — every debit must say poc2)
  balance before 256000, after 135861, spent 120139  ->  LEDGER CONSISTENT: before - after == sum of payments
idempotency: the same key twice must debit once
  call 1: replay=False served by poc2   call 2: replay=True served by poc1   balance differs by exactly 100
```

Note the replay: the duplicate was answered by the *other* cluster and still recognised — the
idempotency key lives in Redis, reached from both.

**Two things the first exercise run found, both fixed and kept in the transcript:**

1. **Call 20 → 502 at the instant of the scale-down.** One request hit the dying pod: the Go
   servers had no graceful shutdown, so SIGTERM killed an open connection before Cilium had
   withdrawn the endpoint. Zero-loss failover is a **contract between the app and the platform**:
   the app now keeps serving for 4 s after SIGTERM (endpoint withdrawal is asynchronous), then
   drains in-flight requests, and the Deployments carry `terminationGracePeriodSeconds: 20`
   (gotcha #53). The re-run above: 0 failures.
2. **Calls 51–60 → 409** were "insufficient funds" — `chk-1002` had 1,016 cents left after the
   earlier runs. A correct business decline, not an outage; the script now counts declines
   separately from infrastructure failures and tops the account up first.

**The web page bug.** "The merchant always shows coffee" — measured through the Gateway with
browser-style POSTs: the merchant *was* stored (`pizza`, `bakery`), but the amount box was read
as raw cents with `Sscanf("%d")`, so `12.50` charged 12 cents, `1,250` charged 1 cent, and `abc`
or an empty box silently added nothing — and the form re-rendered its hard-coded
`value="coffee"`. Now: dollars are parsed (`12.50`, `$7`, `1,250`), invalid input is rejected
**on the page**, the last payment's result is shown with the clusters that handled it, the
merchant is remembered, and every POST is logged.

## Part 6 — resilience drills (`resilience.sh`, recorded in `output/transcript.txt`)

Three failures, each judged by the bank's own responses, not by the platform's status.

**A. `payments` in poc1 scaled to 0 — statically, then 20 payments.** poc1's service map keeps a
single backend, the poc2 pod, and the bank does not notice:

```
53   10.11.166.33:80/TCP   ClusterIP   1 => 10.20.1.95:8080/TCP (active)      <- the only payments backend left: poc2
calls: 20  ok: 20  declined: 0  FAILED (infrastructure): 0
payments served by : poc2=20
LEDGER CONSISTENT: before - after == sum of payments
```

**B. One of the two `accounts` pods killed while balances are read once a second:**

```
reader: 23 ok, 0 failed, longest outage 0s (1 read/s over 25s)
```

The pod drained on SIGTERM (Part 5) and Cilium had already stopped sending to it.

**C1. `postgres-0` deleted — the system of record itself:**

```
balances before: chk-1001=57120 chk-1002=135761
>>> 01:57:16 deleting postgres-0 (uid 0ada1c08…)
>>> 01:57:21 a NEW postgres-0 (uid 73f40e6a…) is Ready ~6s after the delete
reader: 53 ok, 3 failed, longest outage 3s (1 read/s over 60s)
PVC data-postgres-0 -> PV pvc-3cdad16b-…  (the same volume, before and after)
balances after : chk-1001=57120 chk-1002=135761  -> DATA SURVIVED the pod
```

A three-second window in which reads fail (there is one primary; nothing hides that), then the
StatefulSet's replacement pod mounts the **same** PersistentVolume and every balance is what it
was. `accounts` retried its connection rather than crash-looping (its startup loop).

**C2. `redis-0` deleted — payment history and idempotency keys:**

```
payments listed before: 20 (key res-84817-28259 just paid)
a NEW redis-0 is Ready ~6s after the delete; AOF replayed: 1161 keys
payments listed after : 20 -> HISTORY SURVIVED
replaying key res-84817-28259 after the restart: replay=True   balance unchanged
```

`--appendonly yes` on the PVC means the key that was claimed before the restart still blocks a
second debit after it — idempotency survives the store's own restart.

**What the drills do not prove.** The volumes are kind's `local-path` (`/var/local-path-provisioner/…`
on one node): data survives the *pod*, not the *node*. Production needs replicated storage or a
managed database, and a Postgres HA topology; one primary is a deliberate simplification here,
and the 3-second outage is its honest cost.

> *Recorded before Part 8 existed and kept as is: this is what a single primary costs. Part 8 then
> replicates the database into the other cluster; the node-local-volume caveat still stands.*

## Part 7 — the working principles, each with its evidence

**"Do we need labels on the Deployments for this to work?" — No.** Checked two ways. The docs
([Global Services](https://docs.cilium.io/en/stable/network/clustermesh/global-services/)) require
exactly one thing: *"defining a Kubernetes service with identical name and namespace in each
cluster and adding the annotation `service.cilium.io/global: "true"`"*; the Service's ordinary
`selector` matches ordinary pod labels (`app: payments`). And the live objects: the `payments`
Deployments in both clusters carry **no** Cilium label or annotation at all (`labels: None`, pod
labels `{app: payments}`), while the Service carries the one annotation. Nothing on the workload
knows it is in a mesh.

| Principle | Mechanism | Where you saw it |
|---|---|---|
| **A global Service merges endpoints, not objects** | each cluster's `clustermesh-apiserver` publishes its endpoints; the other cluster's agents import them into the *local* Service's eBPF map; DNS stays local, so the Service object must exist in both clusters | poc1's map for `accounts` lists a `10.20.x` backend it never scheduled; demo 07's "why DNS does not resolve" |
| **Load balancing is per connection, in eBPF, at the client node** | the SYN picks a backend from the merged map (local or remote); packets go node-to-node over VXLAN; no proxy in the path | 23/17 split across clusters; `served_by` changes per request only once keep-alive was off (#50) |
| **Failover is endpoint withdrawal, not DNS** | a pod that goes away is removed from every cluster's map; the next SYN simply picks another; the ClusterIP and the name never change | 218/0 and 60/60 through a scale-to-0; poc1's map dropping to the single poc2 backend in drill A |
| **`affinity: local` is a preference, not a fence** | local backends preferred; remote used *"if and only if all of local backends are not available"* | 20/20 local, then 20/20 remote after scale-to-0 |
| **Zero-loss needs the app to drain** | endpoint removal is asynchronous; a pod must outlive it, then finish in-flight requests | 1 × 502 at the scale-down instant before; 0 after SIGTERM handling + `terminationGracePeriodSeconds` (#53) |
| **Idempotency across clusters comes from shared state, not from the mesh** | the key is claimed in Redis before money moves; either cluster's `payments` sees the same claim | replay recognised by the *other* cluster; balance unchanged; survives a Redis restart |
| **The system of record has one home and one truth** | `accounts` runs only in poc2, every debit is one guarded `UPDATE … WHERE balance >= amount`; the ledger balances across clusters | `debited by accounts: poc2=60`; `before − after == sum of payments` every run |
| **Durability is the volume's, availability is the topology's** | a StatefulSet re-mounts the same PV; one primary means a short outage | Postgres: same PV, balances identical, 3 s of failed reads |
| **Observability survives the split** | Hubble on each cluster sees its half; the response bodies carry the cross-cluster path end to end | `served_by` chains; demo 01/10 for the flows |

## Part 8 — the database survives its cluster: a hot standby in poc1, streaming from poc2 across the mesh

Part 6 proved data survives a *pod*. This part makes the database survive the **cluster** it lives
in — the operator's requirement: *"DB failures too won't affect the app"*. The mechanism is
PostgreSQL's own streaming replication, run across ClusterMesh; nothing new is invented.

### The design

```
   poc2                                                    poc1
  ┌─────────────────────────────────┐   WAL stream, pod→pod   ┌──────────────────────────────────┐
  │ postgres-0        PRIMARY (PVC) │ ──────────────────────▶ │ postgres-standby-0  HOT STANDBY   │
  │   role replicator, slot         │  through the mesh       │   (PVC) replays continuously,    │
  │   standby_poc1, pg_hba line     │                         │   answers reads, promotable      │
  │                                 │                         │                                  │
  │ accounts ──writes/reads──▶ postgres-primary (global Svc) │                                  │
  │          ──reads if primary is down──▶ postgres-standby (global Svc) ──▶ poc1               │
  └─────────────────────────────────┘                         └──────────────────────────────────┘
```

| Piece | File | What it does |
|---|---|---|
| primary prep | `10-poc2.yaml` (`postgres-init` ConfigMap; applied by hand on the running primary, transcript) | `replicator` role, a **physical replication slot** so WAL is kept while the standby is away (`wal_keep_size` is 0 by default), the `host replication` line the image does not write |
| the "replication pod" | `40-postgres-standby-poc1.yaml` | an init container runs `pg_basebackup … -R --slot` **against the primary in the other cluster**; the stock image then starts as a streaming hot standby (`hot_standby=on` default) |
| global Services | both manifests | `postgres-primary` (backends poc2) and `postgres-standby` (backends poc1), defined in both clusters — the same rule as every other global Service here |
| app fallback | `accounts` (`PG_STANDBY_DSN`) | reads go to the primary and **fall back to the standby** if it does not answer; writes only ever go to the primary — promotion is an operator's decision, not a request's |
| symmetric bootstrap | `10-poc2.yaml` init container `BOOTSTRAP_FROM` | empty volume + unset → `initdb` a primary; empty volume + a host → base backup from it and come up as its standby. Roles are decided by **data** (`standby.signal`), never by which cluster a pod is in — this is what makes failback a rebuild |

Facts read from the live primary before building (not assumed): `wal_level=replica`,
`max_wal_senders=10`, `hot_standby=on` — PostgreSQL 16 defaults, so no restart was needed; only the
role, the slot and the `pg_hba` line were missing.

### The test cases (`dbfailover.sh`, recorded in `output/transcript.txt` — three runs, the first two with failures kept)

**Case 1 — replication is live and crosses the mesh.**

```
primary (poc2) pg_stat_replication:   10.10.4.17/32 state=streaming sync=async replay_lag=0
standby (poc1) pg_stat_wal_receiver:  in_recovery=true status=streaming sender=postgres-primary.bank.svc.cluster.local
the standby's client address is a poc1 pod: 10.10.4.17 — the WAL stream is pod-to-pod across the mesh
write on poc2 (a $0.77 payment) … primary says chk-1001 = 52343   standby says chk-1001 = 52343
standby refuses writes: ERROR:  cannot execute UPDATE in a read-only transaction
```

**Case 2 — the primary pod dies.** Reads keep working from the standby; writes pause for the pod's
restart and resume; replication reattaches through the slot:

```
>>> 02:06:21 deleting postgres-0 (poc2 primary)      >>> 02:06:26 new primary pod Ready ~6s later
loop 45s: reads ok=38 (from standby: 4) failed=0 | writes ok=34 failed=4 longest write outage 4s
replication resumed? primary sees: 1 standby(s) state=streaming
```

**Case 3 — the primary is lost (scaled to 0): promote, repoint, resume.**

```
with the primary gone: read -> 249798 from standby; a payment -> http 500   (reads served by the standby, writes refused: expected)
>>> promoting the standby: SELECT pg_promote()        pg_promote returned t     in_recovery=f
>>> repointing accounts: PG_DSN -> the poc1 database (one env change, one rollout)
payments now (accounts in poc2 writing to the promoted database in poc1, through the mesh): 20 in a row, counted
    20 payments: 20 ok, 0 failed; balance 247798 from primary
```

`accounts` stays in poc2; its writes now cross the mesh to poc1's database. One env change.

**Case 4 — failback to the original topology, gated at every step.**

```
safety net first: pg_dump of the current primary (poc1) -> .tmp/bank-20260912T022302Z.sql
>>> step 1: rebuild poc2 from poc1 as a STANDBY      poc2 in_recovery=t; poc1 sees 1 standby streaming; chk-1001 on poc2 = 247798
>>> step 2: promote poc2, repoint accounts, VERIFY a write lands there      poc2 in_recovery=f timeline=5; a payment -> http 201
>>> step 3: only now rebuild poc1 as poc2's standby   poc1 standby rebuilt after ~12s: in_recovery=t
final: primary(poc2) sees 1 standby, state=streaming; balances primary=247797 standby=247797; a payment -> http 201
```

### What the first two runs got wrong — all kept in the transcript

1. **The standby's readiness probe required `pg_is_in_recovery() = true`.** So the instant it was
   promoted it went NotReady, left its own Service, and nothing could reach the new primary:
   *"pg_promote returned t"* and every write still 500. A readiness probe must never encode a
   **role** (gotcha #54). Fixed: `pg_isready` only.
2. **The failback deleted both volumes without verifying anything** — the poc2 rebuild was waiting
   on a Service with no endpoints (fault 1), the script did not check, went on to delete poc1's
   volume too, and the two init containers deadlocked on each other's empty Service. The ledger
   from before the failback was lost; the primary was re-initialised with seed data. Demo data —
   and exactly the outage a real runbook exists to prevent (gotcha #55). Fixed: `pg_dump` first;
   promote only a **verified streaming** standby; rebuild the other side only after a **verified
   write** on the new primary; stop at the first check that fails.
3. **One 500 after the repoint (second run).** `rollout status` had reported success while the old
   `accounts` pods were still in their 4-second drain — still Ready, still wired to the dead
   primary, still receiving *new* requests. A draining pod must fail readiness immediately and
   finish only what is in flight (gotcha #56). Fixed: `/healthz` returns 503 on SIGTERM; probes
   `periodSeconds: 2, failureThreshold: 1`. Third run: 20/20.

### The runbook, as it now stands

| Event | Action | Downtime seen by the app |
|---|---|---|
| primary pod restarts | nothing — StatefulSet + slot | reads 0 s (standby), writes ≈ pod restart (4 s measured) |
| primary cluster's database lost | `SELECT pg_promote()` on the standby; `kubectl set env deploy/accounts PG_DSN=<standby DSN>` | reads 0 s; writes until the operator promotes + one rollout |
| failback | dump → rebuild the old side as standby → verify streaming → promote → verify a write → rebuild the other side | writes: two short rollouts |

**Honest limits.** Replication is asynchronous (`sync_state=async`, lag measured at 0–0.16 s): a
promotion can lose the last un-replayed transactions — `synchronous_commit` with the standby named
in `synchronous_standby_names` removes that at the cost of write latency across the mesh. Promotion
is manual by design here; production wants an operator with automatic failover and fencing
(CloudNativePG's replica clusters or Patroni), and the volumes are still node-local. What this part
proves is the *shape*: one primary, a continuously replicated standby in the other cluster reached
through the mesh, an app that degrades to read-only rather than failing, and a failback that
verifies before it destroys.

## What to take away

| Claim | Evidence |
|---|---|
| An app can be split across clusters with no code for it — only a Service annotation | `api` in poc1 reaches `accounts` in poc2 by its ordinary DNS name |
| A shared service is active-active by default | 23 / 17 across the two clusters, 40 requests |
| A cluster losing the component costs **zero** requests | 218 ok, 0 fail through a scale-to-0 and back; 254/0 in the first run |
| Prefer-local with failover is one annotation | `affinity: local` → 20/20 local, then 20/20 remote |
| Idempotency holds across clusters | replay returns the stored record, balance unchanged |
| The API is reachable from outside through the Gateway, still crossing the mesh | `https://bankapi.poc.local/api/balance/…` → `api: poc1, accounts: poc2` |
| A wildcard cert/listener matches one label | `api.bank.poc.local` → curl exit 60; `bankapi.poc.local` → 200 |
| Connection pooling hides load balancing | 40/40 to one cluster until keep-alive was disabled |
| Zero-loss failover needs the app to drain on SIGTERM | 1 × 502 at the scale-down instant before; 60/60 after graceful shutdown |
| The ledger stays consistent across clusters | before − after == sum of payments, every run |
| No labels or annotations on workloads — one annotation on the Service | live Deployments carry none; docs require only `service.cilium.io/global` + same name/namespace |
| Data survives the pod, not the node | Postgres/Redis deleted: same PV, balances and keys intact; 3 s read outage; local-path caveat |
| The database survives its cluster | hot standby in poc1 streaming from poc2 (lag 0–0.16 s); primary lost → promote + one env change → 20/20 writes on poc1's database; failback verified at every step |
| A readiness probe must never encode a role | the promoted standby went NotReady and left its Service; every write failed until the probe was `pg_isready` only |
| Never destroy a copy you have not replaced | first failback lost the ledger; now `pg_dump` first and a verified write before any volume is deleted |

## Clean up

```bash
kubectl --context kind-poc1 delete -f demos/15-bank/30-gateway.yaml -f demos/15-bank/20-poc1.yaml
kubectl --context kind-poc2 delete -f demos/15-bank/10-poc2.yaml        # PVCs go with the namespace
```
