# Using the lab: every script and option

Paths are relative to `demos/57-sni-fabric-lab/`. Every script prints its own help with `-h`
or `--help`. The numbers quoted were measured on 2026-10-21 and 2026-10-22 (Podman 6.1.2 on an
Apple-silicon Mac, IBM MQ under amd64 emulation); `output/transcript.txt` holds the full
recorded run.

## Contents

1. [Quick start](#1-quick-start)
2. [All commands at a glance](#2-all-commands-at-a-glance)
3. [URLs and logins](#3-urls-and-logins)
4. [Build and run](#4-build-and-run): `run.sh`, `gen-certs.sh`, `gen-secrets.sh`
5. [Use the lab](#5-use-the-lab): traffic, the MQ client, the chaos switch, tracing an order, telemetry generation,
   the services' own traces
6. [Check the lab](#6-check-the-lab): `verify.sh` and the tests
7. [Operate the lab](#7-operate-the-lab): containers, the dashboard, the telemetry stores
8. [Reference](#8-reference): environment variables, files written, exit codes

## 1. Quick start

```bash
cd demos/57-sni-fabric-lab
scripts/run.sh --fresh                 # build from nothing and check everything (about 8 min)
python3 scripts/load.py --seconds 300  # five minutes of traffic, so the dashboard has data
```

Then open the [URLs](#3-urls-and-logins).

## 2. All commands at a glance

| Command | What it does | Section |
|---|---|---|
| `scripts/run.sh [--fresh]` | Build, start and check the whole lab | [4.1](#41-scriptsrunsh-build-and-check-everything) |
| `scripts/gen-certs.sh [--force] [--out DIR]` | Create the CA and each component's certificate | [4.2](#42-scriptsgen-certssh-the-ca-and-certificates) |
| `scripts/gen-secrets.sh [--force] [--random]` | Write the lab credentials | [4.3](#43-scriptsgen-secretssh-the-lab-credentials) |
| `python3 scripts/load.py [--seconds N] [--rate N] [--port N]` | Send orders, replays, pings and bad-SNI connections | [5.1](#51-scriptsloadpy-traffic) |
| `podman compose run --rm mq-client [hostname\|channel\|nocert]` | Run a native IBM MQ client through Envoy | [5.2](#52-the-mq-client) |
| `PUT /admin/chaos` (admin portal or `curl`) | Make the API's status updates fail or slow down | [5.3](#53-the-chaos-switch) |
| `python3 scripts/trace_order.py [--item NAME] [--wait N] [--port N]` | Place one order and print every hop it took through Envoy | [5.4](#54-scriptstrace_orderpy-follow-one-order) |
| `podman compose run --rm telemetrygen traces ...` | Send synthetic OTLP spans through Envoy | [5.5](#55-telemetrygen-send-test-telemetry) |
| `scripts/verify.sh [phase1\|phase2\|phase3\|phase5\|phase6 ...]` | Run the checks | [6.1](#61-scriptsverifysh-the-checks) |
| `python3 tests/parity.py [--markdown]` | Compare ten dashboard queries in both metric stores | [6.2](#62-the-tests) |
| `python3 tests/...` | Dashboard, browser and Grafana tests | [6.2](#62-the-tests) |
| `podman compose ...` | Status, logs, restart, stop, remove | [7.1](#71-containers) |
| `python3 observability/grafana/build_dashboard.py` | Regenerate the dashboard | [7.2](#72-the-dashboard) |

## 3. URLs and logins

The ports listen on this Mac's loopback only (`127.0.0.1`). The credentials are fixed lab
values written by `scripts/gen-secrets.sh`; they are public, so use them for this lab only.

| What | URL | Login |
|---|---|---|
| Orders page | <https://web.fabric.localtest.me:8443/> | none |
| Admin portal | <https://web.fabric.localtest.me:8443/admin> | token `fabric-admin` |
| Swagger UI | <https://api.fabric.localtest.me:8443/docs> | none; for the `/admin` calls press **Authorize** and enter `fabric-admin` |
| MQ web console | <https://mqconsole.fabric.localtest.me:8443/ibmmq/console> | `admin` / `fabric-mq-admin` |
| Grafana | <http://grafana.fabric.localtest.me:8080/d/sni-fabric-lab/sni-fabric-lab> | none to view; `admin` / `fabric-grafana` to edit |
| Prometheus | <http://prometheus.fabric.localtest.me:8080> | none |
| VictoriaMetrics | <http://victoriametrics.fabric.localtest.me:8080/vmui/> | none; its whole app from this Mac, as Prometheus's: the vmui query and cardinality pages, every API, admin calls included; a container asking the same host name gets only the read API |
| Tempo, VictoriaTraces, VictoriaLogs | through Envoy only; read them in Grafana's **Explore** | Grafana's `admin` / `fabric-grafana` |
| MQ REST API and MQ clients | through Envoy only | `app` / `fabric-mq-app` |
| Postgres | through Envoy only | `fabric` / `fabric-postgres` |

The browser warns about the certificate until the lab's CA is trusted:

```bash
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db certs/ca/ca.crt
```

During a rebuild (`run.sh --fresh`) and during `verify.sh phase5`, pages may error for a few
minutes: those stop and restart containers on purpose. Reload and log in again afterwards.

## 4. Build and run

### 4.1 `scripts/run.sh`: build and check everything

```bash
scripts/run.sh            # create what is missing, start, check
scripts/run.sh --fresh    # remove every container and volume first, then the same
```

| Option | Effect |
|---|---|
| `--fresh` | `podman compose down -v` first: a rebuild from nothing. Orders, MQ messages, Prometheus history, Grafana settings and the telemetry stores' data are lost; certificates and secrets are kept |
| `-h`, `--help` | Print the help |

The steps, in order:

1. `gen-certs.sh` and `gen-secrets.sh` (create only what is missing)
2. `podman compose up -d --build`
3. Recreate any running service whose bind-mounted file, directory, or a file below that
   directory is newer than its container, then wait for every health check
4. `verify.sh` phases 1–3 and phase 6
5. Wait until every compared rate is exactly comparable in both metric stores, compare the
   stores (one retry, once that wait passes again), and run every dashboard query on
   VictoriaMetrics; before phase 5, whose outages leave gaps the two engines bridge differently
6. `verify.sh` phase 5, then `tests/r1-2/test_store_routes.sh` (Envoy refuses admin and
   unapproved write paths to the containers; this Mac gets VictoriaMetrics' whole app) and the Prometheus dashboard tests
7. Print the memory in use, and the URLs with their logins

Everything is also written to `output/transcript.txt`. It stops at the first failed step.
Measured on 2026-10-23: 14 min 49 s from nothing, 92 checks, 0 failures. The comparison step
took 5 min 36 s, nearly all of it waiting: a counter that sat at zero until phases 1-3 (orders created, unknown-SNI resets) is
exactly comparable only once its last zero sample has left the 310 s window, because Prometheus
stops extrapolating at a counter's zero point and VictoriaMetrics never extrapolates. Since R1.5,
phase 6's requeue check moves two more such counters just before this step (the worker's requeues
and Envoy's retries on `orders_api_internal`), and they were the last to become comparable.

### 4.2 `scripts/gen-certs.sh`: the CA and certificates

```bash
scripts/gen-certs.sh                  # create what is missing or due for renewal
scripts/gen-certs.sh --force          # new CA and new certificates
scripts/gen-certs.sh --out /tmp/certs # write somewhere else
```

| Option | Effect |
|---|---|
| `--force` | New CA and every certificate; run `scripts/run.sh` afterwards so the containers get them |
| `--out DIR` | Output folder (default `certs/`, ignored by git) |
| `-h`, `--help` | Print the help |

Without `--force`, a certificate is reissued only when it is missing, not signed by the current
CA, has different names, has a key that does not match, or expires within 30 days. The
Kubernetes equivalent is in `docs/kubernetes-certs.md`.

| Component | Hostnames in its certificate | Used for |
|---|---|---|
| `web` | `web.fabric.localtest.me` | server |
| `orders-api` | `api.fabric.localtest.me` | server |
| `tcp-svc` | `tcp.fabric.localtest.me` | server |
| `mq` | `qm1.fabric.localtest.me`, `mqconsole.fabric.localtest.me` | server and client |
| `mq-client` | `mq-client.fabric.localtest.me` | client (also `tls.p12`, password `fabric-lab`) |

### 4.3 `scripts/gen-secrets.sh`: the lab credentials

```bash
scripts/gen-secrets.sh                    # write the lab credentials that are missing
scripts/gen-secrets.sh --force            # overwrite with the lab credentials
scripts/gen-secrets.sh --force --random   # overwrite with random values
```

| Option | Effect |
|---|---|
| `--force` | Overwrite existing files |
| `--random` | Random 32-character values instead of the lab credentials |
| `-h`, `--help` | Print the help |

| File in `secrets/` | Lab value | Used by |
|---|---|---|
| `admin-token` | `fabric-admin` | the admin portal and `/admin/*` |
| `postgres-password` | `fabric-postgres` | Postgres, orders-api, postgres-exporter |
| `mq-admin-password` | `fabric-mq-admin` | MQ console user `admin` |
| `mq-app-password` | `fabric-mq-app` | MQ user `app`: orders-api, worker, mq-client |
| `grafana-admin-password` | `fabric-grafana` | Grafana user `admin` |
| `worker-token` | `fabric-worker` | the worker's status updates to orders-api (`PUT /orders/{id}/status`) |

After changing them, rebuild with `scripts/run.sh --fresh`: Postgres and Grafana take their
password only when their data volumes are first created.

## 5. Use the lab

### 5.1 `scripts/load.py`: traffic

```bash
python3 scripts/load.py                          # 120 s at 2 orders a second
python3 scripts/load.py --seconds 600 --rate 5   # 10 minutes at 5 a second
```

| Option | Default | Effect |
|---|---|---|
| `--seconds N` | 120 | How long to run; it stops by itself |
| `--rate N` | 2 | New orders per second; each second also sends as many replays (same Idempotency-Key) and TCP pings |
| `--port N` | `$FABRIC_TLS_PORT` or 8443 | Envoy's published TLS port |
| `-h`, `--help` | | Print the help |

Every fifth second it also opens one connection with an unknown SNI, which Envoy must reset.
It does not retry, so a failure shows as it happened. At the end it prints each request kind
with the status it got (0 means no HTTP answer). Measured with the defaults:

```text
   240  GET /tcp/ping -> 200
   240  POST /orders new -> 201
   240  POST /orders replay -> 200
    24  unknown SNI -> reset
```

To place a single order instead, use the Orders page, Swagger, or:

```bash
curl -s --cacert certs/ca/ca.crt -X POST -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" -d '{"item":"cortado","quantity":1}' \
  https://api.fabric.localtest.me:8443/orders
```

### 5.2 The MQ client

```bash
podman compose run --rm mq-client             # the same as hostname
podman compose run --rm mq-client channel
podman compose run --rm mq-client nocert
podman compose run --rm mq-client --help
```

| Mode | What it does | Expected |
|---|---|---|
| `hostname` (default) | `OutboundSNI=HOSTNAME` with the client certificate: puts two messages on `DEV.QUEUE.2` through `qm1.fabric.localtest.me` and gets them back | `RESULT ok: both messages put and got back` |
| `channel` | MQ's default SNI, built from the channel name | `RESULT ok: refused` (Envoy has no chain for it) |
| `nocert` | No client certificate | `RESULT ok: refused` (QM1 requires one) |

The exit status is 0 when the outcome matches what the mode expects.

### 5.3 The chaos switch

Use the admin portal's **Chaos** panel, or:

```bash
curl -s --cacert certs/ca/ca.crt -X PUT -H 'Authorization: Bearer fabric-admin' \
  -H 'Content-Type: application/json' -d '{"fail_rate":0.3,"delay_ms":0}' \
  https://api.fabric.localtest.me:8443/admin/chaos
```

| Field | Range | Effect |
|---|---|---|
| `fail_rate` | 0 to 1 | Share of the worker's status updates orders-api answers with 503 |
| `delay_ms` | 0 to 5000 | Delay added to each status update |
| `fail_next` | 0 to 100, default 0 | The next n status updates fail whatever the rate; `phase6` sets 4 to make the worker requeue an event (R1.5) |

Only the internal status updates are affected, so Envoy's retries show on the dashboard. Set
both to 0 to stop; a setting without `fail_next` sets it to 0. The setting lives in orders-api's memory and resets when it restarts.

### 5.4 `scripts/trace_order.py`: follow one order

```bash
python3 scripts/trace_order.py
python3 scripts/trace_order.py --item "flat white" --wait 60
```

| Option | Default | Effect |
|---|---|---|
| `--item NAME` | `cortado` | What to order |
| `--wait N` | 30 | Seconds to wait for the order to be processed; exits 1 if it is not |
| `--port N` | `$FABRIC_TLS_PORT` or 8443 | Envoy's published TLS port |
| `-h`, `--help` | | Print the help |

It places one order, waits until it is processed, and prints the hops from Envoy's access log:
the TLS connection passed through `edge_sni`, the event's put on MQ, the worker's get, and the
status update, each with Envoy's attempts and cluster. Entries are picked by time, so run it
while no load is running. Measured:

```text
order 602 created: created, events sent 1
order 602 now: processed
2026-10-21T22:09:37.694Z  DELETE mqrest.mesh:18080/ibmmq/rest/v3/messaging/qmgr/QM1/queue/DEV.QUEUE.1/message -> 200 attempts=1 cluster=mq_web
2026-10-21T22:09:39.182Z  TLS    api.fabric.localtest.me -> orders_api_tls (passed through, 1940 bytes in)
2026-10-21T22:09:39.187Z  POST   mqrest.mesh:18080/ibmmq/rest/v3/messaging/qmgr/QM1/queue/DEV.QUEUE.1/message -> 201 attempts=1 cluster=mq_web
2026-10-21T22:09:39.227Z  PUT    api.mesh:18080/orders/602/status -> 200 attempts=1 cluster=orders_api_internal
```

The worker's get starts before the order: it is a long poll that waits up to 5 s for a message.

### 5.5 `telemetrygen`: send test telemetry

The tools-profile generator sends OTLP only to Envoy's `otlp.mesh` alias; Envoy forwards
`/v1/*` to the collector. It is created for the command and removed afterwards:

```bash
podman compose run --rm telemetrygen traces --otlp-http \
  --otlp-endpoint otlp.mesh:18080 --otlp-insecure --traces 5
```

Each trace is a parent and one child span (`--child-spans` defaults to 1), so `--traces 5`
adds ten to `otelcol_receiver_accepted_spans_total`. telemetrygen exits 0 even when a trace
export fails; a failure shows as a `traces export:` line in its output (its `metrics` and
`logs` commands exit non-zero instead). The collector takes OTLP over HTTP only, on port 4318,
which only Envoy can reach; gRPC needs an L4 route and is added only if a source cannot send
HTTP.

The collector sends traces to Tempo and VictoriaTraces (the same traces to both), metrics to
VictoriaMetrics and logs to VictoriaLogs, each through its Envoy alias. Give a run its own
service name to find it there afterwards:

```bash
podman compose run --rm telemetrygen traces --otlp-http \
  --otlp-endpoint otlp.mesh:18080 --otlp-insecure --traces 5 --service my-run
podman compose run --rm telemetrygen metrics --otlp-http \
  --otlp-endpoint otlp.mesh:18080 --otlp-insecure --metrics 5 --service my-run
podman compose run --rm telemetrygen logs --otlp-http \
  --otlp-endpoint otlp.mesh:18080 --otlp-insecure --logs 5 --service my-run
```

In Grafana's Explore: Tempo `{resource.service.name="my-run"}`, VictoriaTraces service
`my-run`, VictoriaMetrics `gen{"service.name"="my-run"}`, VictoriaLogs
`service.name:="my-run"`. VictoriaTraces and VictoriaMetrics show new data about 30 s after it
arrives (their `-search.latencyOffset`).

### 5.6 The services' own traces

orders-api, worker and tcp-svc start under `opentelemetry-instrument` (each Dockerfile's `CMD`), and
the `x-otel-env` block of `compose.yaml` is their whole configuration; the services' own code adds
only the trace's hand-off through IBM MQ (R1.5, [the tracing page](tracing.md)). They
send traces only, over OTLP/HTTP to Envoy's `otlp.mesh`, which the collector fans out to Tempo and
VictoriaTraces. Their metrics stay on Prometheus's scrape and their logs on stdout.

| Service | Instrumented | Its spans |
|---|---|---|
| orders-api | FastAPI, httpx, psycopg | a server span per request (both servers), a client span per MQ REST, Prometheus or health call, a client span per SQL statement and per pool check (an empty statement named after the database); a `send DEV.QUEUE.1` span per event put |
| worker | httpx | a `process DEV.QUEUE.1` span per message, in the trace of the span that put it, with a client span per status update and a `send` span per requeue or dead-letter put under it; no span for its gets |
| tcp-svc | nothing | none: no library it uses has an instrumentation, so it exports no span |

Not traced: `/metrics`, `/healthz` and `/readyz` on orders-api (`OTEL_PYTHON_FASTAPI_EXCLUDED_URLS`),
because Prometheus's scrape and the health check would be a trace every few seconds. Since R1.5
an order is one trace, from its request through MQ to the worker's status update.

To see one order's trace, place the order with a trace id of your own and open that id in
Grafana's Explore (Tempo):

```bash
trace="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
curl -s --cacert certs/ca/ca.crt -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" -H "traceparent: 00-${trace}-00f067aa0ba902b7-01" \
  -d '{"item":"flat white","quantity":1}' https://api.fabric.localtest.me:8443/orders
echo "${trace}"
```

## 6. Check the lab

### 6.1 `scripts/verify.sh`: the checks

```bash
scripts/verify.sh                 # phases 1, 2 and 3
scripts/verify.sh phase2          # one phase
scripts/verify.sh phase6          # the collector, the four stores, Grafana's datasources
scripts/verify.sh phase1 phase5   # several, in that order
```

| Argument | Checks | What it proves |
|---|---|---|
| `phase1` | 18 | TLS passes through Envoy to web and tcp-svc; unknown and missing SNI are reset; components are isolated |
| `phase2` | 20 | Swagger; idempotent orders; validation; the admin token; CORS; Postgres only through `mesh_pg` |
| `phase3` | 19 | The native MQ client in all three SNI modes; an order from created to processed; every `/metrics` through Envoy; Envoy's verified TLS to the MQ REST API |
| `phase5` | 7 | 50% chaos, a Postgres restart, MQ stopped and started, tcp-svc stopped and started: everything recovers by itself. **Stops and restarts containers on purpose** |
| `phase6` | 27 | Five synthetic traces (ten spans) reach the collector through Envoy with no export error; the collector shares only the internal `net-otel` with Envoy; its internal metrics return through `mesh_http`. Each store is ready when read through Envoy, sits on an internal network shared with Envoy alone, and its own metrics return through `mesh_http`. Both metric stores have the same complete set of healthy jobs, the same positive MQ scrape sample count, and the same positive count of fresh MQ recovery-log gauges. Grafana's test of each datasource answers OK. One named run: its five trace ids are the same in Tempo and VictoriaTraces, one trace has exactly two spans in both, its five metric samples are in VictoriaMetrics, and its five log lines (carrying one of those trace ids) are in VictoriaLogs. orders-api, worker and tcp-svc run under `opentelemetry-instrument`; one order placed with the check's own trace context has, in Tempo, its server span with an HTTP and a database client span under it; the orders-api and worker spans carry `service.name`, `service.version` and `deployment.environment=lab`; the worker's processing of that order's event, and its status update, are in the order's trace, and so is a later attempt after a forced requeue |
| (none) | 57 | `phase1 phase2 phase3` |

Each check prints `PASS` or `FAIL` with what it saw. Phase 4 (metrics) is checked by the
dashboard tests below.

### 6.2 The tests

```bash
python3 tests/dashboard_queries.py
python3 tests/dashboard_queries.py --prometheus http://victoriametrics.fabric.localtest.me:8080
python3 tests/parity.py
python3 tests/parity.py --markdown
python3 tests/test_dashboard.py
~/.local/share/diagram-kit/.venv/bin/python tests/browser_flows.py out/ secrets/admin-token
~/.local/share/diagram-kit/.venv/bin/python tests/grafana_capture.py out/
~/.local/share/diagram-kit/.venv/bin/python tests/vmui_capture.py out/
```

| Test | Arguments | Checks |
|---|---|---|
| `tests/dashboard_queries.py` | `[dashboard.json] [--prometheus URL] [--minutes N]` | Every dashboard query returns without error or warning; lists each series' latest value; flags empty ones |
| `tests/parity.py` | `[dashboard.json] [--prometheus URL] [--victoriametrics URL] [--markdown] [--window-ready]` | Ten exact dashboard queries at one timestamp have identical label sets. Gauges match at T; rates match Prometheus at T with only `rate`'s range widened to `[310s]`, the exact MetricsQL value for the same regular samples. Each rate's raw samples in `[310s]` must also match in count per label set, which an interior lost or repeated sample, or a label renamed under `sum()`, would break. A shared gauge hole at T passes only when both stores agree at T−s and T+s. Empty queries fail, OTLP-only dotted labels are excluded, and `--window-ready` requires a complete `up` window, every selected rate's exact cross-engine comparison, and its raw-sample counts to be ready |
| `tests/test_dashboard.py` | `[grafana.json] [perses.json]` | Sections, charts, colours, line styles, units, legends and `[5m]` windows, in both dashboard forms |
| `tests/r1-3/test_prometheus_config.sh` | none | `promtool` accepts the committed scrape-and-remote-write config; a malformed `remote_write` copy is a failing negative control |
| `tests/r1-3/test_parity.py` | none | Lab-free controls for all measured value pairs, exact gauge copies and cross-engine rates, dropped/stale/duplicated samples, shared one-scrape gauge holes, one-sided and empty comparisons |
| `tests/browser_flows.py` | `<out-dir> <admin-token-file>` | In Chromium, light and dark: places an order, pings over TCP, refuses a wrong token, opens the portal; no console error or CSP violation |
| `tests/grafana_capture.py` | `<out-dir> [prometheus\|victoriametrics]` | The dashboard as an anonymous viewer, dark and light: every chart present, no "No data", "NaN", "not found" or error; with a datasource uid, opened on that datasource with its name in the Datasource menu |
| `tests/vmui_capture.py` | `<out-dir>` | VictoriaMetrics' own UI from the Mac, light and dark: a query of the shop's traffic per Envoy upstream and the cardinality explorer; no page error, no response of 400 or more, each page's expected text |

The three browser tests need Playwright and Chromium, from diagram-kit's environment.

CI runs on every pull request that touches this demo
([`.github/workflows/demo57-ci.yaml`](../../../.github/workflows/demo57-ci.yaml)): shellcheck,
mdfmt, compose config, the Envoy and collector validations and the tests that need nothing of
the lab running; the five tests that need Podman and the lab's images but start nothing
(`test_compose_collector.sh`, `test_key_isolation.py`, `test_status_auth.sh`,
`test_prometheus_baseline.sh`, `test_plugin_checksum.sh`); and diagram-kit's check of the
diagram pages. The tests that need the running lab are listed in the workflow's header, each
with its command.

## 7. Operate the lab

### 7.1 Containers

```bash
podman compose ps                  # what runs, and its health
podman compose logs -f envoy       # Envoy's JSON access log: every hop
podman compose logs -f otel-collector # export errors, when a store cannot be reached
podman compose logs -f worker      # the worker's event handling
podman compose restart grafana     # after regenerating the dashboard
podman compose up -d --build       # start, or apply a change
podman compose stop                # stop, keep everything
podman compose down                # remove the containers, keep the volumes
podman compose down -v             # remove the containers and the volumes
```

`otel-collector`, `tempo`, `victoria-traces` and `victoria-logs` run continuously but have no
Compose health check: their distroless images have no shell or HTTP client. `phase6` checks
them through Envoy instead. `telemetrygen` is a run-on-demand tools-profile container and is
not started by `compose up`.

### 7.2 The dashboard

```bash
python3 observability/grafana/build_dashboard.py
~/.local/share/diagram-kit/.venv/bin/perses-dashboard observability/grafana/dashboards/fabric.json \
  observability/perses/fabric.json --datasource prometheus
python3 tests/test_dashboard.py
podman compose restart grafana
```

`build_dashboard.py` is the source: edit it, never the JSON. The second command generates the
Perses form. In Grafana, the **Datasource** menu defaults to **Prometheus** and offers
**VictoriaMetrics** beside it; every chart follows that selection. The Perses converter does
not preserve Grafana's datasource variable: it emits an empty `variables` list and fixes its
queries to the `prometheus` datasource supplied by `--datasource`, so that form remains
Prometheus-only and was not hand-edited. Grafana 12.4.12 did not reload a changed dashboard
file while running, so restart it. What each chart shows and why:
`docs/metrics/dashboard-choices.md`.

### 7.3 The telemetry stores

Each store has its own internal network, shared with Envoy alone. The collector writes and
Grafana reads through Envoy aliases on `mesh_http`; Envoy routes only the approved write paths,
the read API Grafana uses and the readiness probe (anything else, such as an admin or delete API,
gets Envoy's 404). Prometheus is the sole scraper through `metrics.mesh` and remote-writes every
sample through Envoy's mesh-only `victoriametrics.mesh/api/v1/write` route. This matters because
MQ's exporter consumes its queue-manager gauges on read: a second scraper made Prometheus fall
from 136 to 108 MQ samples and lose the recovery-log latency gauge. VictoriaMetrics runs no
scraper; each store's own metrics remain at `/metrics/<store>`. On the host, VictoriaMetrics is the whole
app, as Prometheus is: <http://victoriametrics.fabric.localtest.me:8080/vmui/> for its own UI.

| Container | Image | Alias on `mesh_http` | Writes | Reads (Grafana datasource `uid`) | Ready | UID |
|---|---|---|---|---|---|---|
| `tempo` | `grafana/tempo:3.1.0`, monolithic, local storage | `tempo.mesh` | `/v1/traces` (to its port 4318) | `/api/` (`tempo`) | `/ready` | 10004 |
| `victoria-traces` | `victoriametrics/victoria-traces:v0.12.0` | `victoriatraces.mesh` | `/insert/opentelemetry/v1/traces` | `/select/jaeger/` (`victoriatraces`, Jaeger type) | `/health` | 10005 |
| `victoria-metrics` | `victoriametrics/victoria-metrics:v1.153.0` | `victoriametrics.mesh`; the whole app on the host at `victoriametrics.fabric.localtest.me` | `/api/v1/write` from Prometheus and `/opentelemetry/v1/metrics` from the collector | the Prometheus query API (`victoriametrics`) | `/health`, and a Compose health check | 10006 |
| `victoria-logs` | `victoriametrics/victoria-logs:v1.53.0` | `victorialogs.mesh` | `/insert/opentelemetry/v1/logs` | `/select/logsql/` (`victorialogs`, plugin v0.32.0) | `/health` | 10007 |

Data lives on the volumes `tempodata`, `vtracesdata`, `vmetricsdata` and `vlogsdata`, each
owned by its store's UID (the init container sets it). Retention is each store's default:
Tempo 14 days, VictoriaMetrics one month, VictoriaLogs and VictoriaTraces 7 days.

Grafana runs `localhost/fabric-grafana:dev`, built from `observability/grafana/image/Dockerfile`:
`grafana/grafana:12.4.12` with the VictoriaLogs plugin added at build time, because the lab
has no internet. The build checks the plugin archive against GitHub's SHA-256 digest pinned in
the Dockerfile and against the SHA-1 in the release's checksums file, and fails on a mismatch.
The plugin is signed by its vendor; Grafana reports its signature `valid`, so no unsigned
plugin is allowed.

## 8. Reference

### 8.1 Environment variables

| Variable | Default | Read by |
|---|---|---|
| `FABRIC_TLS_PORT` | 8443 | compose (Envoy's published TLS port), `verify.sh`, `load.py` |
| `FABRIC_OPS_PORT` | 8080 | compose (Envoy's published port for Grafana, Prometheus and VictoriaMetrics) |
| `OPENSSL` | `openssl` | `gen-certs.sh`, `verify.sh` |
| `OTEL_*` | `x-otel-env` in `compose.yaml` | orders-api, worker and tcp-svc, through `opentelemetry-instrument` (section 5.6) |

Only the defaults are tested. Another TLS port also needs orders-api's `CORS_ORIGINS`
(default `https://web.fabric.localtest.me:8443`), and another operations port needs Grafana's
and Prometheus's external URLs in `compose.yaml` and the admin portal's links.

### 8.2 Files the scripts write

| Path | Written by | In git |
|---|---|---|
| `certs/` | `gen-certs.sh` | no: private keys |
| `secrets/` | `gen-secrets.sh` | no |
| `output/transcript.txt` | `run.sh` | yes: the recorded run |
| `output/load.txt` | a recorded `load.py` run | yes |
| `observability/grafana/dashboards/fabric.json` | `build_dashboard.py` | yes |
| `observability/perses/fabric.json` | `perses-dashboard` | yes |
| `localhost/fabric-grafana:dev` (image) | `podman compose up --build` | no |

### 8.3 Exit status

| Command | 0 means | Otherwise |
|---|---|---|
| `run.sh` | every step passed | the failed step's own status (for `verify.sh`, its number of failures); the transcript shows which step |
| `gen-certs.sh`, `gen-secrets.sh` | done | 1: a bad argument or a tool error |
| `verify.sh` | no check failed | the number of failed checks |
| `mq-client` | the outcome the mode expects | 1 |
| `tests/*.py` | all passed | 1 or more |
