# SNI fabric lab: plan

**Status:** phases 1 to 6 built and checked (2026-10-21): `scripts/run.sh --fresh` passes from
nothing (`output/transcript.txt`); the guide, record and exercises are `RECAP.md`, `README.md`, `GUIDE.md`. The plan below is kept as written,
with the facts building changed corrected in place and listed in section 10.

**Goal:** a small microservice app on Docker Compose (run with `podman compose`) in which
**Envoy is the only path between any two components**. It exercises a shared wildcard
SNI listener (one TLS port, routed on the hostname each client sends) with real clients: a browser, a
REST API with Swagger, a raw TCP service, IBM MQ, and a database. Metrics and retries are
part of the design, not added later.

## 1. What runs

All hostnames are under `*.fabric.localtest.me`, which public DNS resolves to `127.0.0.1`
(checked: `dig +short web.demo.localtest.me` and `a.b.c.localtest.me` both return
`127.0.0.1`), so the browser needs no `/etc/hosts` edits.

| # | Component | What it is | Image (arch) | Browser / client entry |
|---|---|---|---|---|
| 1 | `envoy` | The fabric: every listener below | `envoyproxy/envoy:v1.36.2` (arm64) | — |
| 2 | `web` | Front end over TLS, two pages: **Orders** (create orders, watch their status, ping the TCP service) and the **Admin portal** (section 4a) | `nginxinc/nginx-unprivileged` (arm64) | `https://web.fabric.localtest.me` and `/admin` |
| 3 | `orders-api` | REST API (FastAPI): orders CRUD, `/admin/*` for the portal, `/docs` (Swagger UI), `/openapi.json`, `/metrics` | Python 3.12 slim (arm64) | `https://api.fabric.localtest.me/docs` |
| 4 | `worker` | Takes order events off MQ, marks each order processed through the API | Python 3.12 slim (arm64) | — (metrics only) |
| 5 | `tcp-svc` | Raw TCP line protocol over TLS (`PING`, `TIME`, `ECHO <text>`), not HTTP | Python 3.12 slim (arm64) | `openssl s_client -servername tcp.fabric.localtest.me` |
| 6 | `mq` | IBM MQ queue manager `QM1`, TLS on `DEV.APP.SVRCONN`, web console + REST API on 9443, metrics on 9157 | `icr.io/ibm-messaging/mq` 10.0.1.0 (**amd64, emulated**) | `https://mqconsole.fabric.localtest.me:8443/ibmmq/console` |
| 7 | `mq-client` | One-shot native MQ client (`amqsputc`/`amqsgetc`) with `OutboundSNI=HOSTNAME` | same MQ image (amd64) | `qm1.fabric.localtest.me(10443)`, Envoy's listener inside the lab |
| 8 | `postgres` | Orders table | `postgres:17-alpine` (arm64) | — |
| 9 | `postgres-exporter` | Database metrics | `prometheuscommunity/postgres-exporter` | — |
| 10 | `prometheus` | Scrapes every target **through Envoy** | `prom/prometheus` | `http://prometheus.fabric.localtest.me:8080` |
| 11 | `grafana` | Dashboard, Prometheus data source through Envoy | `grafana/grafana` | `http://grafana.fabric.localtest.me:8080` |

Exact image tags are pinned at build time to releases at least two weeks old.

**Measured on this Mac (2026-10-21):** the MQ image has no arm64 build (`amd64`, `s390x`,
`ppc64le` only); the Podman VM runs amd64 through qemu (`uname -m` → `x86_64`); a probe
`QM1` reached `Running` in about 40 s and used **981.5 MB**. The VM has 4 GiB, and the
`secure-notes` containers already running use about 127 MB in total.

## 2. Envoy is the only path: enforced, not by convention

Each component gets its own Compose network shared only with Envoy (`net-web`, `net-api`,
`net-worker`, `net-tcp`, `net-mq`, `net-db`, `net-obs`). Envoy is on all of them; nothing
else shares a network. So `orders-api` cannot even resolve `postgres`: it can only reach
Envoy. Phase 2 proves this with a failing direct connection.

Inside the networks, Envoy carries the public hostnames as network aliases
(`api.fabric.localtest.me`, `qm1.fabric.localtest.me`, …), so a container that dials a
public name reaches Envoy, exactly as the browser does.

## 3. Envoy listeners

| Listener | Port (host) | Layer | Routes on | Carries |
|---|---|---|---|---|
| `edge_sni` | 10443 (**8443**) | L4, TLS passthrough | SNI | `web`, `api`, `tcp`, `qm1` (MQ), `mqconsole` (MQ web) — the section 9 design, unchanged |
| `ops_http` | 10080 (**8080**) | L7 HTTP | `Host` | `grafana`, `prometheus` for the browser |
| `mesh_http` | 18080 (none) | L7 HTTP | `Host` and path | east-west HTTP: `worker → orders-api`, `orders-api/worker → MQ REST` (Envoy opens TLS to MQ), `prometheus → /metrics/<target>` |
| `mesh_pg` | 15432 (none) | L4 TCP | port | `orders-api`, `postgres-exporter` → `postgres` |
| `stats` | 9902 (none) | L7 HTTP | path | only `/stats/prometheus`, so the admin API itself stays on `127.0.0.1:9901` |

`orders-api → tcp-svc` and `mq-client → QM1` go through `edge_sni` from inside the
networks, which shows the one shared port serving east-west traffic as well.

## 4. Request flows

1. **Browser → web:** `https://web.fabric.localtest.me` → `edge_sni` → `web` (TLS ends at
   nginx).
2. **Browser → API:** the page calls `https://api.fabric.localtest.me/orders` → `edge_sni`
   → `orders-api` (TLS ends at the API). CORS allows only the web origin.
3. **Create an order:** `POST /orders` with an `Idempotency-Key` header → insert into
   `postgres` (via `mesh_pg`) → put an event on `DEV.QUEUE.1` through the MQ REST API (via
   `mesh_http`) → `201`.
4. **Process it:** `worker` gets the event (MQ REST, `mesh_http`) → `PUT
   /orders/{id}/status` on `orders-api` (via `mesh_http`) → the page shows `processed`.
5. **TCP:** the page's "ping TCP" button → `GET /tcp/ping` → `orders-api` opens TLS to
   `tcp.fabric.localtest.me` through `edge_sni` → `PONG`.
6. **Native MQ through SNI (the main test of the design):** `mq-client` runs `amqsputc` /
   `amqsgetc` with `CONNAME qm1.fabric.localtest.me(10443)`, `OutboundSNI=HOSTNAME` and TLS →
   `edge_sni` → `QM1`.

## 4a. Admin portal

`https://web.fabric.localtest.me/admin`, served by `web`; every call goes to `orders-api`
`/admin/*` through `edge_sni`. Those endpoints require a bearer admin token (a Compose
secret generated locally); the portal asks for it once and keeps it in `sessionStorage`
only.

| Panel | Shows or does | Data from |
|---|---|---|
| Health | Each component green or red: `orders-api`, `worker`, `tcp-svc`, `postgres`, `mq`, `envoy` | `orders-api` `/admin/health`, which checks each one through Envoy |
| Fabric | Connections per SNI tenant, connections rejected for an unknown SNI, retries and retry successes per cluster | Prometheus HTTP API, queried by `orders-api` through `mesh_http` |
| Orders | All orders with their status, filter by status, retry a stuck one | `postgres` through `orders-api` |
| MQ | Messages waiting on `DEV.QUEUE.1` and the dead-letter queue, queue-manager puts and gets, last event seen by `worker` | A REST browse (nothing removed); MQ metrics in Prometheus; `worker` `/metrics` |
| Chaos | Set `orders-api`'s failure rate (0–100 %) and an added delay; shows the retry counters react | `POST /admin/chaos` |
| Links | Swagger, Grafana, Prometheus, MQ web console | — |

## 5. Retry logic, by layer

| Layer | Where | Behaviour | Guard against double effects |
|---|---|---|---|
| Envoy L4 | `edge_sni` chains, `mesh_pg` | `max_connect_attempts: 3` with `backoff_options` (connect failures only; no bytes have been sent yet) | Safe by construction |
| Envoy L7 | `mesh_http` routes for `GET`/`PUT` | `retry_on: connect-failure,reset,5xx`, `num_retries: 3`, `per_try_timeout`, exponential back-off, `previous_hosts` predicate; outlier detection and circuit breakers on each cluster | Only idempotent methods |
| Envoy L7 | `mesh_http` routes for `POST`, and for `DELETE` to the MQ REST API | `retry_on: connect-failure,refused-stream` only (the request never reached the app) | Nothing was processed. The MQ REST "get" is an HTTP `DELETE` that removes the message (a destructive get), so it is never retried after it was sent |
| App | browser → `POST /orders` | Exponential back-off with jitter; the same `Idempotency-Key` on every attempt | Unique key in the database: a repeat returns the first order, never a second one |
| App | `worker` | Back-off loop on MQ or API errors. The REST API has no transactions: a message is gone once got. If the status update still fails after Envoy's retries, the worker puts the event back with a retry count; after 5, onto `DEV.DEAD.LETTER.QUEUE` | `PUT` is idempotent |
| App | `orders-api` sweeper | Re-publishes the event of any order still `created` after 60 s. This covers the one gap the REST API leaves: a worker that dies between the get and the put-back | The worker's `PUT` is idempotent, so a duplicate event is harmless |
| App | `orders-api`, `worker` start-up | Database and MQ connection retries with back-off; `/readyz` stays false until both work | — |

**Showing that retries work:** the admin portal's Chaos panel sets `orders-api`'s failure
rate (`POST /admin/chaos {"fail_rate": 0.5}`). With it on, the worker's updates
still succeed, and Envoy's `upstream_rq_retry` and `upstream_rq_retry_success` counters
climb in Grafana.

## 6. Metrics

| Source | How it is exposed | Examples |
|---|---|---|
| Envoy | `stats` listener `/stats/prometheus` | per-tenant `tcp.<prefix>.*`, `no_filter_chain_match`, `upstream_rq_retry*`, `upstream_rq_time` |
| `orders-api`, `worker` | `/metrics` (`prometheus_client`) | requests by route and status, latency, orders created and processed, MQ put/get, retries seen |
| `tcp-svc` | `/metrics` on a plain HTTP port | connections, commands by type |
| `mq` | `MQ_ENABLE_METRICS=true`, port 9157 | queue-manager-wide only (`ibmmq_qmgr_*`): puts, gets, log write latency |
| `postgres` | `postgres-exporter` | connections, transactions, table rows |

Prometheus scrapes every target through `mesh_http` (`/metrics/<target>` rewritten to the
target's own path). The Grafana dashboard is built with diagram-kit's `/dashboard` skill:
a metrics inventory of what each target actually emits comes first, then the panels, then
screenshots in light and dark themes.

## 7. Phases, each ending in a test

| Phase | Builds | Done when (measured, shown to you) |
|---|---|---|
| 1 | Local CA and certificates, `envoy` (`edge_sni`), `web` (both pages, static), `tcp-svc` | Both pages load in the browser; `openssl` to `tcp` gets `PONG`; an unknown SNI is reset |
| 2 | `orders-api`, `postgres`, `mesh_pg`, the per-component networks | Swagger works; create/list orders; a direct `orders-api → postgres` connection fails |
| 3 | `mq` with TLS, `worker`, `mesh_http`, `mq-client` | `amqsputc`/`amqsgetc` through `qm1.fabric.localtest.me:10443` with `OutboundSNI=HOSTNAME`; an order goes `created → processed` |
| 4 | `prometheus`, `postgres-exporter`, `grafana` + dashboard; the admin portal's live panels | Every target `up` in Prometheus; the dashboard and the portal drawn, screenshots in both themes |
| 5 | Retry and failure tests | Chaos on: updates still succeed and the retry counters rise; restart `postgres` and `mq`: the services recover on their own |
| 6 | README with every command and its result, plus the architecture diagram | You can run the whole lab from the README |

## 8. Where it lives

`demos/57-sni-fabric-lab/`. It holds no company identifiers: every hostname is under
`fabric.localtest.me`, and every other name (`QM1`, `DEV.APP.SVRCONN`, `orders-api`) is a
generic default.

## 9. Risks and open points

| Item | Plan |
|---|---|
| Host port 443 | Refused: rootless Podman's VM does not bind ports below 1024. The lab uses 8443 and 8080, on 127.0.0.1 only. |
| Memory | `QM1` alone used 981.5 MB of the 4 GiB VM. Measured again after phase 4; if it is tight, raising the VM's memory restarts the VM and the `secure-notes` containers, so that needs your go-ahead. |
| MQ under emulation | Start-up worked; throughput is not a goal. Each MQ step has a timeout so a hang fails loudly. |
| MQ TLS in the developer image | Keys go in `/etc/mqm/pki/keys/<label>`; the exact channel settings are confirmed in phase 3 against the image's own docs. |
| Passwords | Fixed, documented lab credentials (`scripts/gen-secrets.sh`, operator's choice 2026-10-21), written to `secrets/` and handed to each component by the init container; MQ 9.4 reads its own from files (`MQ_ADMIN_PASSWORD` / `MQ_APP_PASSWORD` are deprecated). Public, so for this loopback-only lab only; `--random` writes random ones |
| Browser trust | The lab's CA is generated locally. Trusting it in the macOS keychain removes the browser warnings; that step is yours, and the README gives the command. |

## 10. What building changed

| Planned | Built, and why |
|---|---|
| Host port 443 | 8443 (TLS) and 8080 (operations), bound to `127.0.0.1`: rootless Podman refuses ports below 1024, and the LAN has no business reaching a lab |
| Keys and secrets mounted from `certs/` and `secrets/` | A one-shot `init` container copies each component's key and secrets into volumes, owned by the UID that component runs as (`scripts/init-volumes.sh`): a bind mount of a `600` file is unreadable to a non-root container user. The queue manager gets volumes of its own, because it shares UID 1001 with `mq-client` |
| Per-queue MQ depth from metrics | The MQ container exports queue-manager-wide series only; the portal counts waiting messages with a REST browse |
| Envoy's 5xx counter as "failed attempts" | It counts only the final answer: 93 injected failures, 92 retries, 2 final 5xx (measured). The dashboard sets orders-api's own 5xx count beside Envoy's |
| MQ healthy when the queue manager is | The web server (REST API, console) starts after it; the health check now waits for port 9443 too |
| Counters as Envoy and postgres-exporter name them | Seven renamed to end in `_total` at the scrape, so Prometheus 3 raises no "might not be a counter" notice |
| The client keystore built from PEM | The MQ image has no `openssl`; `gen-certs.sh` also writes `mq-client/tls.p12`, which `runmqakm` imports (measured: GSKit accepts OpenSSL 4's PBES2/AES-256 format) |
| The Grafana plugin checked against its release's SHA-256 checksums file | That file publishes a SHA-1; the image build checks it and GitHub's SHA-256 digest of the asset, pinned in the Dockerfile |
