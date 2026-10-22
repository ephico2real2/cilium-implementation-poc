# Demo 57 — SNI fabric lab: the record

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide. [GUIDE.md](GUIDE.md) has the
exercises, [docs/usage.md](docs/usage.md) every script and option. Where it goes next:
[docs/roadmap/ROADMAP.md](docs/roadmap/ROADMAP.md).

A Compose lab, run with Podman, in which Envoy is the only path between any two components:
one TLS port routed on SNI for every client, a mesh of HTTP and TCP listeners for every call
inside, with retries and metrics. This page records how it is run, what each step printed on
the last recorded run (`output/transcript.txt` and its companion files in `output/`), and what
went differently while it was built.

## Summary context — the enterprise case

An IBM MQ queue manager behind a load balancer that passes TLS through to a shared Envoy, with
one wildcard DNS name and one port for every tenant, chosen by SNI. MQ clients must then send
the hostname as SNI (`OutboundSNI=HOSTNAME`), and Envoy must never terminate their TLS.

This lab runs that design end to end with generic names (`*.fabric.localtest.me`, `QM1`,
`DEV.APP.SVRCONN`), so it can be shown, measured and broken without any real system.

## Files

| File | What |
|---|---|
| `compose.yaml` | Every service, its own internal network, and Envoy's aliases on each |
| `envoy/envoy.yaml` | The listeners `edge_sni`, `mesh_http`, `mesh_pg`, `ops_http`, `stats` and their clusters |
| `services/orders-api/` | FastAPI: orders, `/admin/*`, Swagger; public TLS server and internal server |
| `services/worker/` | Takes order events off MQ (REST), marks orders processed |
| `services/tcp-svc/` | A raw TLS line protocol: `PING`, `TIME`, `ECHO` |
| `web/` | nginx config and the Orders and Admin pages |
| `mq/` | The channel's mutual-TLS setting, the MQ client's CCDT and script |
| `observability/` | Prometheus config; Grafana provisioning, the dashboard generator and both dashboard forms |
| `scripts/` | `run.sh`, `gen-certs.sh`, `gen-secrets.sh`, `init-volumes.sh`, `verify.sh`, `load.py`, `trace_order.py` |
| `tests/` | Dashboard queries and structure, browser flows, Grafana capture |
| `k8s/cert-manager/certificates.yaml` | The certificates as cert-manager objects, for later |
| `docs/` | Usage, the Kubernetes certificate note, the metrics inventory and choices, diagrams, screenshots |
| `PLAN.md` | The plan, with what building changed |
| `output/` | The recorded run, the load run, the MQ client run, the exercises |

## Run it

```bash
cd demos/57-sni-fabric-lab
scripts/gen-certs.sh
scripts/gen-secrets.sh
podman compose up -d --build
scripts/verify.sh
podman compose run --rm mq-client hostname
python3 scripts/load.py --seconds 120
scripts/verify.sh phase5
```

Or all of it, from nothing, recorded:

```bash
scripts/run.sh --fresh
```

## What was recorded

### 1. Create the CA and the certificates

```bash
scripts/gen-certs.sh
```

```text
kept   web        web.fabric.localtest.me
kept   orders-api api.fabric.localtest.me
kept   tcp-svc    tcp.fabric.localtest.me
kept   mq         qm1.fabric.localtest.me,mqconsole.fabric.localtest.me
kept   mq-client  mq-client.fabric.localtest.me

COMPONENT   CHAIN    NAMES                                                  USAGE                  EXPIRES
web         ok       web.fabric.localtest.me                                Server                 Nov 22 20:38:05 2027 GMT
orders-api  ok       api.fabric.localtest.me                                Server                 Nov 22 20:38:05 2027 GMT
tcp-svc     ok       tcp.fabric.localtest.me                                Server                 Nov 22 20:38:06 2027 GMT
mq          ok       mqconsole.fabric.localtest.me,qm1.fabric.localtest.me  Server, Client         Nov 22 20:38:06 2027 GMT
mq-client   ok       mq-client.fabric.localtest.me                          Client                 Nov 22 20:38:06 2027 GMT

```

### 2. Write the lab credentials

```bash
scripts/gen-secrets.sh
```

```text
kept    admin-token
kept    postgres-password
kept    mq-admin-password
kept    mq-app-password
kept    grafana-admin-password
kept    worker-token
```

### 3. Start the lab

```bash
podman compose up -d --build
```

```text
envoy            healthy after 0s
web              healthy after 0s
tcp-svc          healthy after 6s
orders-api       healthy after 6s
postgres         healthy after 6s
mq               healthy after 130s
worker           healthy after 130s
prometheus       healthy after 130s
grafana          healthy after 130s
victoria-metrics healthy after 130s
```

### 4. Check the shared port and the services

```bash
scripts/verify.sh
```

```text
== Phase 1: edge_sni, web, tcp-svc
PASS  web: Orders page over TLS, CA-verified         200 0
PASS  web: Admin portal page                         <title>Fabric Admin</title>
PASS  web: Content-Security-Policy header            content-security-policy: default-src 'self'; connect-src 'self' https:
PASS  edge_sni: TLS ends at web, not Envoy           subject=O=SNI Fabric Lab, CN=web.fabric.localtest.me
PASS  tcp-svc: PING                                  PONG
PASS  tcp-svc: ECHO                                  hello fabric
PASS  tcp-svc: HELP                                  COMMANDS PING TIME ECHO HELP QUIT
PASS  tcp-svc: unknown command                       ERR unknown command
PASS  tcp-svc: QUIT                                  BYE
PASS  tcp-svc: TIME is today's UTC date              2026-10-22T18:45:34+00:00
PASS  tcp-svc: over-long line refused                ERR line too long
PASS  edge_sni: unknown SNI is reset                 no peer certificate available 
PASS  edge_sni: missing SNI is reset                 no peer certificate available 
PASS  envoy: no_filter_chain_match rose by 2         0 -> 2
PASS  isolation: tcp-svc cannot resolve web          socket.gaierror: [Errno -2] Name or service not known
PASS  isolation: web cannot reach tcp-svc            nc: bad address 'tcp-svc'
PASS  isolation: tcp-svc has no route out            socket.gaierror: [Errno -2] Name or service not known
PASS  isolation: tcp-svc cannot read web's key       cat: /tls/web/tls.key: Permission denied
== Phase 2: orders-api, postgres, mesh_pg
PASS  api: Swagger UI at /docs                           <link type="text/css" rel="stylesheet" href="https://cdn.jsdelivr.
PASS  api: OpenAPI lists /orders and /admin/chaos    orders-api True True
PASS  orders: POST creates (201)                     HTTP 201
PASS  orders: same key replays (200)                 HTTP 200
PASS  orders: replay header                          idempotent-replayed: true
PASS  orders: replay returns the same order          {"id":1,"item":"espresso","quantity":2,"status":"processed","created_a
PASS  orders: same key, other body refused (422)     HTTP 422
PASS  orders: missing Idempotency-Key refused        HTTP 422
PASS  orders: quantity over 20 refused               HTTP 422
PASS  orders: GET by id                              espresso 2
PASS  orders: status update not exposed publicly     HTTP 404
PASS  tcp: API pings tcp-svc through edge_sni        {"reply":"PONG","latency_ms":8.7,"attempts":1}
PASS  admin: no token refused                        HTTP 401
PASS  admin: wrong token refused                     HTTP 401
PASS  admin: envoy, postgres, web, tcp-svc up        envoy=True postgres=True web=True tcp-svc=True mq=True worker=True
PASS  admin: chaos rejects a rate over 1             HTTP 422
PASS  cors: web origin allowed                       access-control-allow-origin: https://web.fabric.localtest.me:8443
PASS  cors: other origin not allowed                 no allow-origin header
PASS  isolation: orders-api cannot resolve postgres  socket.gaierror: [Errno -2] Name or service not known
PASS  envoy: Postgres traffic went through mesh_pg   tcp.postgres.downstream_cx_total=28
== Phase 3: IBM MQ, worker, mesh_http
PASS  mq: put and get with OutboundSNI=HOSTNAME      RESULT ok: both messages put and got back through Envoy with OutboundS
PASS  mq: channel-name SNI refused                   RESULT ok: refused as expected for mode channel
PASS  envoy: channel SNI had no chain                no_filter_chain_match 2 -> 3
PASS  mq: no client certificate refused              RESULT ok: refused as expected for mode nocert
PASS  mq console: TLS ends at MQ, name verified          Verify return code: 0 (ok)
PASS  mq console: redirects to its login page        302 https://mqconsole.fabric.localtest.me:8443/ibmmq/console/login.htm
PASS  mq: REST API reachable through mesh_http       True (after 0s)
PASS  flow: order 4 created -> processed             processed 1 (after 1s)
PASS  admin: every component up                      envoy=True postgres=True web=True tcp-svc=True mq=True worker=True
PASS  metrics: /metrics/envoy through mesh_http      5643 samples
PASS  metrics: /metrics/orders-api through mesh_http 245 samples
PASS  metrics: /metrics/tcp-svc through mesh_http    39 samples
PASS  metrics: /metrics/worker through mesh_http     43 samples
PASS  metrics: /metrics/mq through mesh_http         136 samples
PASS  worker: processed counter                      worker_messages_total{result="processed"} 2.0
PASS  envoy: verified TLS to the MQ REST API         cluster.mq_web.ssl.handshake=13
PASS  envoy: MQ certificate name matched             fail_verify_san=0
PASS  isolation: worker cannot resolve mq            socket.gaierror: [Errno -2] Name or service not known
PASS  isolation: worker cannot resolve orders-api    socket.gaierror: [Errno -2] Name or service not known

failures: 0
```

### 5. Put and get with the native MQ client

```bash
podman compose run --rm mq-client hostname
```

```text
mode=hostname OutboundSNI=HOSTNAME -> qm1.fabric.localtest.me:10443 (Envoy edge_sni) -> QM1
  put: Sample AMQSPUT0 start
  put: target queue is DEV.QUEUE.2
  put: Sample AMQSPUT0 end
  get: Sample AMQSGET0 start
  get: message <fabric 20261021T221803Z-11733 one>
  get: message <fabric 20261021T221803Z-11733 two>
  get: no more messages
  get: Sample AMQSGET0 end
RESULT ok: both messages put and got back through Envoy with OutboundSNI=HOSTNAME
(exit 0)
```

### 6. Send traffic

```bash
python3 scripts/load.py --seconds 120
```

```text
   240  GET /tcp/ping -> 200
   240  POST /orders new -> 201
   240  POST /orders replay -> 200
    24  unknown SNI -> reset
```

### 7. Break things and watch them recover

```bash
scripts/verify.sh phase5
```

```text
== Phase 5: failures and recovery
PASS  chaos 50%: every order still processed         processed=10 of 10 after 0s
PASS  chaos 50%: Envoy retried the failed PUTs       upstream_rq_retry 0 -> 5
PASS  postgres restart: API recovers on its own      order 38 created 1 attempt(s) after the restart
PASS  mq down: order still accepted, no event yet    created 0
PASS  mq back: the sweeper's resend gets it processed processed=1 of 1 after 9s
PASS  tcp-svc down: ping fails cleanly               HTTP 502
PASS  tcp-svc back: ping works again                 {"reply":"PONG","latency_ms":4.8,"attempts":1}

failures: 0
```

### 8. Check the collector and the telemetry stores

```bash
scripts/verify.sh phase6
bash tests/r1-2/test_store_routes.sh
```

```text
== Phase 6: OpenTelemetry collector and the telemetry stores
PASS  otel: a span reaches the collector through Envoy accepted spans 322 -> 408 (10 sent)
PASS  isolation: the collector shares a network only with Envoy network=fabric_net-otel (internal), peer=fabric-envoy-1
PASS  metrics: the collector's own metrics through mesh_http 54 samples
PASS  store: tempo ready, reached only through Envoy ready after 0s; net-tempo (internal) shared with Envoy alone
PASS  metrics: /metrics/tempo through mesh_http      646 samples
PASS  store: victoria-traces ready, reached only through Envoy OK after 0s; net-vtraces (internal) shared with Envoy alone
PASS  metrics: /metrics/victoria-traces through mesh_http 491 samples
PASS  store: victoria-metrics ready, reached only through Envoy OK after 0s; net-vmetrics (internal) shared with Envoy alone
PASS  metrics: /metrics/victoria-metrics through mesh_http 980 samples
PASS  store: victoria-logs ready, reached only through Envoy OK after 0s; net-vlogs (internal) shared with Envoy alone
PASS  metrics: /metrics/victoria-logs through mesh_http 488 samples
PASS  stores: same healthy metric jobs               11 jobs: envoy mq orders-api otel-collector postgres tcp-svc tempo victoria-logs victoria-metrics victoria-traces worker
PASS  stores: MQ gauge and sample count copied       fresh gauges=1 in both; scrape_samples_scraped=136 in both
PASS  grafana: datasource prometheus answers OK      status=OK Successfully queried the Prometheus API.
PASS  grafana: datasource victoriametrics answers OK status=OK Successfully queried the Prometheus API.
PASS  grafana: datasource victorialogs answers OK    status=OK Data source is working
PASS  grafana: datasource tempo answers OK           status=OK Data source is working
PASS  grafana: datasource victoriatraces answers OK  status=OK Data source is working
PASS  stores: the same 5 trace ids in Tempo and VictoriaTraces phase6-c40c0fea after 27s, e.g. 44668b9f805eabf3d0fa70c5d216b3d4
PASS  stores: one trace has two spans                Tempo=2, VictoriaTraces=2 (parent + child)
PASS  stores: the run's metrics in VictoriaMetrics   5 of 5 samples after 30s
PASS  stores: the run's logs in VictoriaLogs         5 lines with trace_id 44668b9f805eabf3d0fa70c5d216b3d4 after 3s
PASS  otel: the three services run instrumented      orders-api:orders-api:instrumented worker:worker:instrumented tcp-svc:tcp-svc:instrumented
PASS  otel: one order's trace has server, client and database spans server=1 client=1 database=6 traces=1 spans=12
PASS  otel: resource has service, version, env=lab   orders-api=dev/lab worker=dev/lab spans=13 missing=0

failures: 0
```

```text
ok        POST victoriametrics.mesh/api/v1/admin/tsdb/delete_series?match[]=gen -> Envoy 404
ok        POST victoriametrics.mesh/api/v1/import -> Envoy 404
ok        POST victoriametrics.mesh/api/v1/write -> upstream 204
ok        GET victoriametrics.mesh/snapshot/create -> Envoy 404
ok        GET victorialogs.mesh/internal/force_merge -> Envoy 404
ok        GET victoriatraces.mesh/select/logsql/query?query=* -> Envoy 404
ok        GET tempo.mesh/status/config -> Envoy 404
ok        GET tempo.mesh/flush -> Envoy 404
ok        POST tempo.mesh/api/echo -> Envoy 404
ok        GET tempo.mesh/v1/traces -> Envoy 404
ok        POST tempo.mesh/ready -> Envoy 404
ok        GET victoriatraces.mesh/insert/opentelemetry/v1/traces -> Envoy 404
ok        POST victoriatraces.mesh/health -> Envoy 404
ok        GET victoriametrics.mesh/opentelemetry/v1/metrics -> Envoy 404
ok        POST victoriametrics.mesh/health -> Envoy 404
ok        GET victorialogs.mesh/insert/opentelemetry/v1/logs -> Envoy 404
ok        POST victorialogs.mesh/health -> Envoy 404
ok        GET victoriametrics.mesh/api/v1/query?query=1 -> 200
ok        POST victoriametrics.mesh/api/v1/query?query=1 -> 200
ok        GET victorialogs.mesh/select/logsql/query?query=*&limit=1 -> 200
ok        POST victorialogs.mesh/select/tenant_ids -> 200
ok        GET victoriametrics.mesh/api/v1/rules -> 200
ok        GET victoriametrics.mesh/api/v1/alerts -> 200
ok        GET tempo.mesh/api/echo -> 200
ok        GET victoriatraces.mesh/select/jaeger/api/services -> 200
ok        GET tempo.mesh/ready -> 200
ok        GET victoriatraces.mesh/health -> 200
ok        GET victoriametrics.mesh/health -> 200
ok        GET victorialogs.mesh/health -> 200
ok        GET victoriametrics.fabric.localtest.me/api/v1/query?query=1 -> 200
ok        POST victoriametrics.fabric.localtest.me/api/v1/query?query=1 -> 200
ok        GET victoriametrics.fabric.localtest.me/ -> 200, holds 'Single-node VictoriaMetrics'
ok        GET victoriametrics.fabric.localtest.me/vmui/ -> 200, holds '<title>vmui</title>'
ok        GET victoriametrics.fabric.localtest.me/vmui/assets/index-COkkZ7F8.js -> 200
ok        GET victoriametrics.fabric.localtest.me/api/v1/status/tsdb -> 200
ok        GET victoriametrics.fabric.localtest.me/api/v1/status/top_queries -> 200
ok        GET victoriametrics.fabric.localtest.me/flags -> 200
ok        GET victoriametrics.fabric.localtest.me/metrics -> 200
ok        GET victoriametrics.fabric.localtest.me/snapshot/list -> 200
ok        GET victoriametrics.fabric.localtest.me/api/v1/admin/tsdb/delete_series -> 405
ok        POST victoriametrics.fabric.localtest.me/api/v1/import -> 204
ok        POST victoriametrics.fabric.localtest.me/api/v1/import from a container -> Envoy 404
ok        POST victoriametrics.fabric.localtest.me/api/v1/write from a container -> Envoy 404
ok        GET victoriametrics.fabric.localtest.me/api/v1/admin/tsdb/delete_series from a container -> Envoy 404
ok        GET victoriametrics.fabric.localtest.me/snapshot/list from a container -> Envoy 404
mismatches: 0
```

## Checks

```bash
python3 tests/dashboard_queries.py --minutes 5
python3 tests/test_dashboard.py
```

```text
EMPTY  Status updates: 5xx answered vs. 5xx that reached the work  B  series=0  
31 queries, 0 with errors or warnings, 1 empty, 0.08 s in all
PASS  14 charts in 7 sections; both forms agree on colours, styles, units, legends
```

The two refused MQ modes, and MQ's own record of the second:

```text
$ podman compose run --rm mq-client channel

mode=channel OutboundSNI=CHANNEL -> qm1.fabric.localtest.me:10443 (Envoy edge_sni) -> QM1
  put: Sample AMQSPUT0 start
  put: MQCONNX ended with reason code 2393
RESULT ok: refused as expected for mode channel
(exit 0)

$ podman compose run --rm mq-client nocert

mode=nocert OutboundSNI=HOSTNAME -> qm1.fabric.localtest.me:10443 (Envoy edge_sni) -> QM1
  put: Sample AMQSPUT0 start
  put: MQCONNX ended with reason code 2393
RESULT ok: refused as expected for mode nocert
(exit 0)

$ podman exec fabric-mq-1 grep -h -E "^AMQ9(637|999)" /var/mqm/qmgrs/QM1/errors/AMQERR01.LOG | tail -2
AMQ9637E: During handshake, the remote partner sent no certificate.
AMQ9999E: Channel 'DEV.APP.SVRCONN' to host 'fabric-envoy-1 (10.89.9.2)' ended
```

## What is deliberately not here

- No Kubernetes or Envoy Gateway: the lab is Compose; `docs/kubernetes-certs.md` maps the
  certificates onto cert-manager.
- No high availability: one of each component; Envoy's outlier detection and panic threshold
  are configured but have a single host per cluster.
- No real credentials: the lab values are public, and the ports listen on `127.0.0.1` only.
- No per-queue MQ metrics: the MQ container exports queue-manager-wide series only; the admin
  portal counts waiting messages with a REST browse.
- No transactional MQ get: the REST get is destructive; the sweeper re-sends any order's event
  that has not been processed after 60 s.
- The queue manager's plain-text `SYSTEM.*` channels exist, but nothing reaches port 1414
  except TLS with the `qm1` SNI.

## Runs that did not go to plan

**Port 443.** `rootlessport cannot expose privileged port 443`: rootless Podman binds no port
below 1024, so the lab publishes 8443 and 8080.

**Keys in bind mounts.** A non-root container cannot read a `600` key owned by the host user.
The `init` container now copies each component's key and secrets into volumes owned by that
component's UID (`scripts/init-volumes.sh`).

**MQ's web server.** The REST API answered `503 … Connection refused` while the queue manager
was already healthy: the web server starts after it. The health check now waits for port 9443.

**Envoy's 5xx counter.** With 30% chaos, orders-api answered 93 status updates with 503 while
Envoy's `upstream_rq_xx` (class 5) read 2: Envoy counts only the final answer. The dashboard's
retry section was redrawn to set orders-api's own count beside Envoy's.

**Grafana and the dashboard file.** A rewritten `fabric.json` was not reloaded while Grafana
ran, with or without a version bump; restarting Grafana loads it.

**A lost event after a restart.** An order created seconds after Envoy was restarted stayed
`created`: a REST get left waiting inside MQ took its event. The sweeper re-sent it and the
order was processed 75 s after it was created. The worker now logs every failed get.

## Clean up

```bash
podman compose down -v
rm -rf certs secrets
```
