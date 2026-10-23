# Tracing, as built

This page explains how the lab traces a request today: how orders-api, the worker and tcp-svc
make spans, almost all without a line of tracing code, the path a span takes to Tempo and
VictoriaTraces, what one order's trace holds, how the trace crosses IBM MQ, and what is not traced
yet. Story R1.4 built the zero-code part, with its decisions and reviews in
[reviews/R1.4.md](reviews/R1.4.md) and this page's own review in
[reviews/115-tracing-page.md](reviews/115-tracing-page.md); story R1.5 (#98) carried the trace
through MQ. Every number here was measured on the running lab on 2026-10-22 and 23, and the
output it comes from is named beside it.

## Words used here

| Word | Meaning |
|---|---|
| Span | One timed piece of work, such as one HTTP request served or one SQL statement, with a name, a start, a duration and attributes |
| Trace | The spans of one piece of work, joined by parent and child; they share one 32-hex-digit **trace id** |
| Kind | What a span is to its service: `server` (a request it serves), `client` (a call it makes), `internal` (work inside it) |
| `traceparent` | The W3C Trace Context HTTP header that carries the trace id and the caller's span id to the next service: `00-<trace id>-<parent span id>-01` |
| Instrumentation | A library that wraps another (FastAPI, httpx, psycopg) and makes spans for its calls |
| OTLP | The OpenTelemetry protocol; here, spans as protobuf over HTTP, `POST /v1/traces` |
| Collector | The OpenTelemetry Collector, the one process every span goes through on its way to the stores |
| Resource | The attributes of the process that made a span: `service.name`, `service.version`, `deployment.environment` |

## How a span is made

Each image starts its program under `opentelemetry-instrument`, which loads the installed
instrumentations, configures them from `OTEL_*` environment variables, and then runs the same
command. Only the hand-off through IBM MQ, which no instrumentation can see, has code of its own
([Across IBM MQ](#across-ibm-mq-one-order-one-trace)):

```dockerfile
# services/orders-api/Dockerfile
CMD ["opentelemetry-instrument", "python", "-m", "app.main"]
```

What each service installs decides what it traces. The packages are named one by one in each
`requirements.txt` and pinned with hashes in its `requirements.lock`; `opentelemetry-bootstrap`,
which would guess them, is not used.

| Service | Instrumentations | What gets a span |
|---|---|---|
| orders-api | `fastapi`, `httpx`, `psycopg` (all 0.66b1) | every request it serves except the three routes excluded below, every HTTP call it makes, every SQL statement; and, from its own code, a `send` span per event put on MQ |
| worker | `httpx` | every HTTP call it makes except its MQ gets: its status updates to orders-api, and the puts that requeue or dead-letter an event; and, from its own code, a `process` span per message and a `send` span per put |
| tcp-svc | none (the distro only) | nothing: it serves raw TCP, which no instrumentation covers |

All three take the same settings from one YAML anchor in [`compose.yaml`](../compose.yaml):

| Variable | Value | Why |
|---|---|---|
| `OTEL_SERVICE_NAME` | `orders-api`, `worker`, `tcp-svc` | the name each trace shows |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otlp.mesh:18080` | Envoy's alias for the collector; the SDK adds `/v1/traces` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | required: the distro defaults it to `grpc` (`os.environ.setdefault(OTEL_EXPORTER_OTLP_PROTOCOL, "grpc")` in `opentelemetry.distro`), and the lab routes OTLP over HTTP only |
| `OTEL_TRACES_EXPORTER` | `otlp` | send spans |
| `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER` | `none` | traces only: metrics stay on Prometheus's scrape until R1.8, logs on stdout until R1.7 |
| `OTEL_PROPAGATORS` | `tracecontext,baggage` | read and write the W3C `traceparent` header |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | keep every trace; follow the caller's sampling decision when there is a caller |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.version=dev,deployment.environment=lab` | the resource every span carries; `dev` is the images' tag |
| `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS` | `/metrics$,/healthz$,/readyz$` (orders-api only; `$$` in Compose) | Prometheus's scrape every 10 s and the health check every 5 s would each be a trace |

## The path a span takes

![Senders on the left (telemetrygen for phase 6, orders-api and the worker since R1.4, Envoy's own spans proposed for R1.6) post OTLP to Envoy's otlp.mesh route on mesh_http; Envoy passes it to the collector, which batches it and exports through Envoy again to Tempo and VictoriaTraces, and metrics and logs to VictoriaMetrics and VictoriaLogs. Grafana reads every store through Envoy aliases.](diagrams/layers/telemetry.light.png)

*The telemetry layer. Solid boxes are built and checked; the dashed one, Envoy's own spans, is
R1.6.*

```text
1 MAKE    orders-api, worker: each span ends --> the SDK's batch processor (sends every 5 s)
2 SEND    POST http://otlp.mesh:18080/v1/traces --> Envoy mesh_http, route "otlp" (retried only if never received)
                                                --> otel-collector :4318
3 BATCH   collector: memory_limiter --> batch
4 STORE   collector --> Envoy (tempo.mesh /v1/traces)                                --> Tempo 3.1
                    --> Envoy (victoriatraces.mesh /insert/opentelemetry/v1/traces)  --> VictoriaTraces
5 READ    Grafana --> Envoy (tempo.mesh, victoriatraces.mesh) --> the trace, by id or by search
```

Every span passes Envoy twice on its way to each store, and no service talks to the collector or a
store directly: each sits on its own network with Envoy alone. The collector's trace pipeline is in
[`observability/otel-collector.yaml`](../observability/otel-collector.yaml) (`exporters:
[otlp_http/tempo, otlp_http/victoriatraces]`); Envoy's route is the `otlp` virtual host in
[`envoy/envoy.yaml`](../envoy/envoy.yaml).

## One order's trace

`tests/trace_capture.py` places one order through Envoy's edge with a `traceparent` it made
itself, as `phase6` does, so the trace id is known before any store is asked. Its output, in
[`output/trace-capture.txt`](../output/trace-capture.txt), captured on 2026-10-23 with R1.5 built:

```text
order   43 placed, HTTP 201, traceparent 00-0d18438652aa4aa893eb1edfb2c7a3ea-211d988b0a9344ff-01
tempo   order trace 0d18438652aa4aa893eb1edfb2c7a3ea: 22 spans, client=10 consumer=1 internal=8 producer=1 server=2
vtraces order trace 0d18438652aa4aa893eb1edfb2c7a3ea: the same 22 span ids
```

![Grafana Explore on the Tempo datasource showing trace 0d184386…, orders-api: POST /orders, 64.35 ms, 22 spans, 2 services: the server span with INSERT, send DEV.QUEUE.1 and its 52.93 ms POST, under the send the worker's process DEV.QUEUE.1 span in blue with its PUT, orders-api's PUT /orders/{order_id}/status and its UPDATE, then the order's UPDATE and SELECT.](screenshots/trace-order-tempo.light.png)

*The order's trace in Tempo, 2026-10-23: one order, one trace, 2 services. The long bars are the
event's put on IBM MQ (`send DEV.QUEUE.1` and its `POST`, 52.93 ms of the 64.35 ms); the worker's
spans, in blue, sit under the send, and orders-api's status update under the worker's `PUT`.*

The 22 spans, read back from Tempo's API:

| Spans | Service, kind | Made by | What they are |
|---|---|---|---|
| `POST /orders` | orders-api, server | FastAPI | the request; its parent is the caller's span from `traceparent` |
| `POST /orders http receive`, 3 × `POST /orders http send` | orders-api, internal | FastAPI (ASGI) | reading the request body; sending the response start and its body |
| `INSERT`, `UPDATE`, `SELECT` | orders-api, client | psycopg | the order written (with its `traceparent`), its `events_sent` counted, the row read back |
| `send DEV.QUEUE.1` | orders-api, producer | `app/clients.py` (R1.5) | the event's put; its `traceparent` rides in the message |
| `POST` | orders-api, client | httpx | the put itself, through `mqrest.mesh` |
| `process DEV.QUEUE.1` | worker, consumer | `worker.py` (R1.5) | the worker handling the event; its parent is the send span |
| `PUT` | worker, client | httpx | the status update, through `api.mesh` |
| `PUT /orders/{order_id}/status`, its receive and 3 sends | orders-api, server and internal | FastAPI | the status update served |
| `UPDATE` | orders-api, client | psycopg | the order marked processed |
| 4 × `fabric` | orders-api, client | psycopg | the connection pool's check before each statement (`check=AsyncConnectionPool.check_connection` in `app/db.py` runs an empty statement; an empty statement's span takes the database's name) |

The worker's `process` span starts at 59.09 ms, before orders-api has sent the order's response
(60.30 ms): the event is handled while the request is still finishing.

`phase6` checks the API's half of this trace: exactly one server span, and under it at least one
HTTP client span and at least one database span, all in the requested trace. Its summary counts
differently from the table: `client` is orders-api's HTTP client spans only (the `POST` to MQ) and
`database` its psycopg spans, the status update's included, so it reads `server=1 client=1
database=8 traces=1 spans=22`; the total is printed, not checked. The worker's half has checks of
its own ([How we know it works](#how-we-know-it-works)).

A trace started by a caller's `traceparent` has its root in the caller, which sends no span, so
Tempo's search lists it as `<root span not yet received>` (`output/tracing-measurements.txt`,
section 5); opened by its id, it shows as above. An order placed with no `traceparent` (the Orders
page's `fetch` sets none, nor does `curl` alone) starts a trace of its own, `POST /orders` with no
parent (measured before R1.5,
[`output/tracing-measurements.txt`](../output/tracing-measurements.txt), section 2).

The collector sends the same spans to VictoriaTraces, which Grafana reads with its Jaeger
datasource:

![Grafana Explore on the VictoriaTraces datasource showing the same trace id, orders-api: POST /orders, 22 spans, 2 services, in the same order as in Tempo.](screenshots/trace-order-victoriatraces.light.png)

*The same trace in VictoriaTraces: the same 22 span ids, names and durations.*

## Across IBM MQ: one order, one trace

The event is a JSON body on `DEV.QUEUE.1`, put and got through MQ's REST API, and no
instrumentation carries trace context through it. Until R1.5 the order and its processing were
two traces: the worker's status update, with orders-api's handling of it, was a trace of its own
(8 spans for order 53, in R1.4's capture, [reviews/115-tracing-page.md](reviews/115-tracing-page.md)),
and so was each of its long-polling gets.

Since R1.5 both services carry the context themselves, in the MQ user property the spike measured
(`output/spike-r1-5-mq-traceparent.txt`): the header `ibm-mq-usr: traceparent;"<traceparent>";string`
on the put, returned on the get. The event body stays as it is.

| Code | What it does | Why |
|---|---|---|
| `services/orders-api/app/clients.py`, `publish_order_event` | puts the event in a `send DEV.QUEUE.1` span (kind producer) and sends that span's W3C `traceparent` in `ibm-mq-usr`, made by OpenTelemetry's `TraceContextTextMapPropagator` | the semantic conventions' creation context: whoever gets the message continues from the span that sent it |
| `app/main.py`, `create_order`; `app/db.py` | stores the order request's `traceparent` on the order row, in the column `orders.traceparent` (`ALTER TABLE … ADD COLUMN IF NOT EXISTS`, so a database from before R1.5 gets it too) | the sweeper and the admin's republish send the event again later, from traces of their own |
| `publish_order_event`, for a re-send | when the order's stored trace is not the current one, the send span's parent is the stored context, with a link to the span that re-sent it (the republish request; the sweeper has no span, so no link); for an order without a stored context (one created before R1.5), the send continues the current trace: the republish request's, or for the sweeper a trace of its own | a link points one way, from the new span to the old: a re-send that only linked to the order would not show from the order's trace |
| `services/worker/worker.py`, the main loop | reads the get's `ibm-mq-usr` headers with httpx's `get_list` and parses them with `mq_properties`, extracts the context with the same propagator, and processes the message in a `process DEV.QUEUE.1` span (kind consumer) whose parent is that context and which links to it, as the conventions ask of every `process` span; a message without a valid `traceparent` starts a trace of its own, with no link | AC 1: the worker's span has the order's trace id; a malformed property never stops the loop |
| `worker.py`, `put` | every put of the worker's own (the requeue, the dead-letter puts) is a `send <queue>` span whose `traceparent` the message carries | AC 2: an event put back after a failed attempt is processed later as a child of that requeue, in the same trace |
| `worker.py`, the main loop | the get runs under `suppress_http_instrumentation()` | an empty long poll every `GET_WAIT_MS` (5000) was a trace of its own: 115 of the worker's 116 traces in 10 idle minutes (`output/r1-5-mq-measurements.txt`, section 7). The conventions ask for a `receive` span on a pull like this one; the lab leaves it out on purpose, and a failed get is counted in `worker_get_errors_total` and logged instead |
| `worker.py`, `dead_letter` | counts a dead-letter put as `dead_lettered` only when MQ took it, and as `lost` when the put failed | the counter said `dead_lettered` whatever the put's answer |

`mq_properties` splits the header the way MQ was measured to write it, not the way the spike's
issue expected: MQ returns every property of a message in one `ibm-mq-usr` header, sorted by name
and joined by commas, and a string value may hold a comma or an escaped quote
(`output/r1-5-mq-measurements.txt`, sections 1 and 2):

```text
all      201 200 ['b;true;boolean,l;7;long,q;"x\\",y";string,traceparent;"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";string']
```

So the list is split only at commas outside quotes, and reading stops at the first entry that does
not parse. Only `traceparent` is carried: MQ refuses a property value that holds a semicolon
(`MQWB0302E`, HTTP 400), and the W3C `tracestate` and `baggage` may hold one, so either could make
the event's put itself fail.

Each span carries the messaging attributes of OpenTelemetry's semantic conventions, and one of
the lab's own:

| Attribute | Value | Why |
|---|---|---|
| `messaging.system` | `ibm_mq` | the conventions register no value for IBM MQ (`jms` names an API the lab does not use); the name follows the registered ones' form, `aws_sqs`, `gcp_pubsub` |
| `messaging.destination.name` | `DEV.QUEUE.1` (or the dead-letter queue) | the queue |
| `messaging.operation.name`, `messaging.operation.type` | `send` or `process` | the span names are `{operation} {queue}`, as the conventions name them |
| `messaging.message.id` | MQ's `ibm-mq-md-messageId`, on a put that answered 201 and on every get | the message itself, as MQ names it |
| `fabric.order.id` | the order's id, on orders-api's send and the worker's process span | to find an order's spans by its id; no convention covers a business id, and a custom attribute takes a namespace of its own, the lab's |
| `error.type` | on a failed span only: the HTTP status (`503`, `500`) or the exception's name (`ReadTimeout`, `ValueError`) | required by the conventions when a messaging operation fails, and absent when it succeeds |

R1.5's own code, run on the lab before it was built into the images (each service's new file
inside its running container, on `DEV.QUEUE.3`, with the worker's status updates answered by a
fake orders-api that failed the first one), made one trace across both services and MQ
(`output/r1-5-mq-measurements.txt`, section 5, attributes left out):

```text
     0.00 ms   r15-probe-orders-api  SERVER   probe POST /orders     -     ''
     0.06 ms     r15-probe-orders-api  PRODUCER send DEV.QUEUE.3       -     ''
     0.32 ms       r15-probe-orders-api  CLIENT   POST                   -     ''
  5885.65 ms       r15-probe-worker      CONSUMER process DEV.QUEUE.3    ERROR 'update failed (attempt 1): 503'
  5912.12 ms         r15-probe-worker      PRODUCER send DEV.QUEUE.3       -     ''
  5912.37 ms           r15-probe-worker      CLIENT   POST                   -     ''
  5949.16 ms           r15-probe-worker      CONSUMER process DEV.QUEUE.3    -     ''
    17.39 ms     r15-probe-orders-api  PRODUCER send DEV.QUEUE.3       -     ''
    17.63 ms       r15-probe-orders-api  CLIENT   POST                   -     ''
  5937.76 ms       r15-probe-worker      CONSUMER process DEV.QUEUE.3    -     ''
```

The first attempt failed and is an error; the requeue is a send span under it, and the second
attempt is that send's child. The second send is a re-send made from another trace (a stand-in for
the admin's republish): it joined the order's trace under the request's span and links to the
request that made it. The probe's worker made no `DELETE` span (section 6), and a span that
arrived 13 minutes after the rest of its trace joined it in Tempo (section 8), as a sweeper's
re-send of an order created while MQ was down would. In the lab's own order trace, the worker's
status update then follows under its `process` span: its `PUT`, orders-api's
`PUT /orders/{order_id}/status` server span and the `UPDATE`, the 8 spans of R1.4's worker trace.

### Reading a lost event from its order's trace

The fresh run of 2026-10-23 lost one event, and the order's trace shows where
([`output/r1-5-lost-message.txt`](../output/r1-5-lost-message.txt)). `phase5` stops MQ, places
order 41, and starts MQ again; the sweeper re-sends the event of any order still `created`. The
order's trace held four sends under its request:

```text
00:58:14.601 orders-api SERVER   POST /orders                   id=40b1c3c332e33a55 parent=- UNSET
00:58:14.604 orders-api PRODUCER send DEV.QUEUE.1               id=63c7ed9ee40259ae parent=40b1c3c332e33a55 ERROR
00:59:29.280 orders-api PRODUCER send DEV.QUEUE.1               id=6f6bbe0b3d75b026 parent=40b1c3c332e33a55 ERROR
00:59:44.805 orders-api PRODUCER send DEV.QUEUE.1               id=6c8ee1a13e6d121d parent=40b1c3c332e33a55 UNSET
01:00:45.349 orders-api PRODUCER send DEV.QUEUE.1               id=3e9ca9842d72732e parent=40b1c3c332e33a55 UNSET
01:00:45.452 worker     CONSUMER process DEV.QUEUE.1            id=c6ce568b8a3a8912 parent=3e9ca9842d72732e UNSET
```

The first two sends failed while MQ was down and starting (HTTP 503 in orders-api's log). The
third succeeded at 00:59:44 and has no `process` span under it: the worker never handled that
message. The worker's log and Envoy's say why (sections 3 and 5 of the record). The worker sent a
get at 00:59:33.671, a second after MQ's REST listener opened and five seconds before the REST
application finished starting, and gave up at its 10-second read timeout (`get failed
(ReadTimeout: timed out)`; Envoy logged the request with `"duration_ms":10010,"flags":"DC"`, its
client gone). MQ's web log puts the REST application's start at 00:59:38.906 and its first
authorisation at 00:59:39.827, with that get the only request in flight, so its 5-second wait was
still open when the event arrived at 00:59:44.8; the worker's next get, at 00:59:46, and every one
to 01:00:41 answered 204. MQ's counters show one put and one destructive get more than its steady
traffic, each 430 bytes more, in the scrape step after the event (00:59:48 to 00:59:58): MQ
publishes its statistics late, and the re-send at 01:00:45, which the worker did process, left the
same signature one step after it too. A REST get is destructive
and not transactional, so the abandoned get took the message for a client that was gone; the
worker is the only consumer of `DEV.QUEUE.1` (orders-api only browses it). The sweeper's next round, a minute later, sent the event again, and the worker
processed it within 103 ms: the `phase5` check "mq back" passed after 69 s instead of R1.4's 9 s.
Before R1.5 the request, the sweeper's three re-sends and the processing would have been five
unconnected traces; now the order's own trace shows that one event reached MQ and was never processed.

## What is not traced, and why

| What | Traced? | Why |
|---|---|---|
| The browser, the Orders page | no | Envoy's edge passes TLS through on SNI, so nothing at the edge sees the request; browser tracing is out of R1's scope |
| Envoy itself | no | `mesh_http` forwards `traceparent` but makes no span of its own; R1.6 (#99) adds that, and the spike measured one span per retry attempt (`output/spike-r1-6-envoy-attempt-spans.txt`) |
| IBM MQ, Postgres | no | they make no spans; the calling service's spans time each call (orders-api for Postgres, its event puts and its queue browses; the worker for its requeues and dead-letter puts) |
| The worker's gets from `DEV.QUEUE.1` | no | suppressed since R1.5: each empty long poll was a trace of its own, 115 in 10 idle minutes (`output/r1-5-mq-measurements.txt`, section 7); the message a get returns is traced by its `process` span, and a failed get is counted in `worker_get_errors_total` and logged |
| `tracestate` and `baggage` across MQ | no | MQ refuses a property value with a semicolon, which both may hold; only `traceparent` is carried |
| orders-api's `/metrics`, `/healthz`, `/readyz` | no | excluded; 0 traces in 30 minutes for each (reviews/R1.4.md) |
| tcp-svc | no span | instrumented, but nothing instruments a raw TCP server; `phase6` checks that it starts under `opentelemetry-instrument` |
| orders-api's background work | yes | the sweeper's `SELECT` every 15 s (`SWEEP_EVERY_S`) and its pool checks are traces of their own (38 and 42 in 10 minutes, reviews/R1.4.md); since R1.5 an event it sends again joins the order's trace |
| Logs beside a span | not yet | R1.7 (#100) writes the trace id into every log line and links a span to its logs |

## How we know it works

`scripts/verify.sh phase6` checks tracing on every run. Re-run on 2026-10-23 with R1.5 and its review fixes built, in
[`output/phase6-tracing.txt`](../output/phase6-tracing.txt), `failures: 0`:

| Check | What it proves | Result |
|---|---|---|
| `otel: a span reaches the collector through Envoy` | telemetrygen sends 10 spans through `otlp.mesh` with no export error, and the collector's accepted-span counter rises by at least 10 (the services' own spans count too, so here it rose by 14) | accepted spans 5235 → 5249 |
| `otel: the three services run instrumented` | each service's process 1 has the installed hook directory on its `PYTHONPATH`, and its log holds no `Failed to auto initialize OpenTelemetry` | `orders-api:orders-api:instrumented worker:worker:instrumented tcp-svc:tcp-svc:instrumented` |
| `otel: one order's trace has server, client and database spans` | an order placed with the check's own `traceparent` has, in that trace and under orders-api's server span, orders-api's HTTP and database client spans | `server=1 client=1 database=8 traces=1 spans=22` |
| `otel: resource has service, version, env=lab` | in the order's whole trace (22 spans here, both services), every orders-api and worker span has a version and `deployment.environment=lab`, and both services appear; a span with no `service.name` counts as missing, and spans of other named services are not checked | `orders-api=dev/lab worker=dev/lab spans=22 missing=0` |

R1.5 adds two checks to `phase6`. Since the worker makes spans only for the messages it
processes, the resource check reads the order's whole trace, both services in it, instead of one
of the worker's polls.

| Check | What it proves | Result |
|---|---|---|
| `otel: the worker's span joins the order's trace` | the order placed for the check above has, in its trace, a worker `process` span naming that order (`fabric.order.id`) whose parent is orders-api's `send` span for it under the order's server span, and that order's status update answering 200 under the worker's `PUT` in one of its attempts | `server=1 first=1 first_ok=1 requeued=0 later=0 later_ok=0 traces=1` |
| `otel: a requeued event's later attempt joins the trace` | with the next 4 status updates set to fail (`fail_next`, one per try of Envoy's: a first try and `num_retries: 3`), a second order's first attempt fails, the worker's requeue is a `send` span under it, a later attempt is that send's child, and that attempt's update answers 200, all in the order's trace; chaos is reset afterwards | `server=1 first=1 first_ok=0 requeued=1 later=1 later_ok=1 traces=1` |

`tests/scripts/test_verify_false_pass.sh` feeds the checks the cases R1.4's and R1.5's reviewers
found would fool them, and wants the right verdict: a service whose hook loaded but failed to
start, a look-alike path on `PYTHONPATH`, another service's or another trace's spans in the
order's slots, a resource without `service.name`, a worker span outside the order's send, a
later attempt's update counted for the first, a dead-letter put taken for a requeue, spans naming
another order (what a context leaked from another message would make), an update with no worker
`PUT` above it. It guards
against those known cases, not every possible one, and needs no lab:

```bash
bash tests/scripts/test_verify_false_pass.sh scripts/verify.sh   # last line: mismatches: 0
```

`tests/scripts/test_mq_trace_context.sh` runs the services' code in their built images against a
fake MQ and a fake orders-api, its spans in memory: the header parse on the shapes MQ was measured
to return, each message processed under the span that put it, a requeued attempt as the child of
the requeue, a message without a valid `traceparent` processed in a trace of its own, no span for
the gets, orders-api's send span, a re-send joining the order's trace, and `fail_next`. CI runs it
with the images it builds:

```bash
bash tests/scripts/test_mq_trace_context.sh services certs/ca/ca.crt   # last line: mismatches: 0
```

## Check it yourself

From the demo directory, with the lab running:

```bash
# Place an order with a trace id you choose, through Envoy's edge
trace_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
curl -s -w '\n' --cacert certs/ca/ca.crt -X POST https://api.fabric.localtest.me:8443/orders \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" \
  -H "traceparent: 00-${trace_id}-$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-16)-01" \
  -d '{"item":"flat white","quantity":1}'
echo "trace id: ${trace_id}"

# Its spans in Tempo (from Grafana's container, which holds tempo.mesh). The services export
# every 5 s, so wait first; Tempo answers a trace it does not hold yet with an empty one.
sleep 10
podman exec fabric-grafana-1 curl -fsS "http://tempo.mesh:18080/api/v2/traces/${trace_id}" \
  | python3 -c 'import json,sys; print(sorted(s["name"] for r in json.load(sys.stdin)["trace"].get("resourceSpans", []) for x in r["scopeSpans"] for s in x["spans"]))'
```

The last command prints the trace's span names: orders-api's, `send DEV.QUEUE.1` among them, and
once the worker has processed the event, `process DEV.QUEUE.1` and the spans of its status update;
`[]` means they have not reached Tempo yet, so run it again. To see the trace, open
<http://grafana.fabric.localtest.me:8080/explore>, choose **Tempo**, then **TraceQL**, paste the
trace id and run the query. The pictures on this page are taken by `tests/trace_capture.py`. It
takes them only once the trace holds the spans this page discusses: the order's server span under
the `traceparent` it sent, with `INSERT`, the send to MQ and its `POST`, `SELECT`, the worker's
`process` span under the send with its `PUT`, orders-api's `PUT /orders/{order_id}/status` under
that, and two `UPDATE`s, the event count and the status; then the same span ids in VictoriaTraces.
The library's own spans (ASGI send and receive, the pool's checks) are counted, not required. Each
page must then show its span count and names, and a run that fails half-way keeps the last set:

```bash
~/.local/share/diagram-kit/.venv/bin/python tests/trace_capture.py docs/screenshots
```

## The twelve factors it touches

The roadmap scores the lab against the twelve factors ([ROADMAP.md](roadmap/ROADMAP.md)). Tracing
as built touches three of them:

| Factor | What R1.4 did |
|---|---|
| II Dependencies | each instrumentation named in `requirements.txt` and pinned with hashes in `requirements.lock`; nothing installed by guessing (`opentelemetry-bootstrap`) |
| III Config | the image's `CMD` starts each service under `opentelemetry-instrument`; everything else (exporter, endpoint, protocol, sampler, resource) is `OTEL_*` variables in `compose.yaml`; the code does not change |
| XI Logs | still open: logs go to stdout as JSON without a trace id; R1.7 adds it and sends them to VictoriaLogs |

## What comes next

The trace R1 aims for, one order from its `POST` through MQ to the worker's update, with Envoy's
hops drawn, is the approved mock in [`diagrams/r1-trace-mock`](diagrams/r1-trace-mock/source.html):
solid for what R1.4 and R1.5 built, dashed for R1.6.

![The R1 trace mock: orders-api's POST /orders with INSERT, its send to DEV.QUEUE.1 and the httpx POST, and UPDATE; under the send, joined by the traceparent in the MQ message, the worker's process span, its PUT, orders-api's status update and its UPDATE, all built; Envoy's two hops proposed.](diagrams/r1-trace-mock/r1-trace-mock.light.png)

*Solid: built in R1.4 and R1.5. Dashed: Envoy's hops, proposed for R1.6.*

## Sources

- OpenTelemetry Python zero-code instrumentation:
  [overview](https://opentelemetry.io/docs/zero-code/python/),
  [configuration](https://opentelemetry.io/docs/zero-code/python/configuration/);
  [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/);
  [OTLP exporter settings](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/).
- [W3C Trace Context](https://www.w3.org/TR/trace-context/), the `traceparent` header.
- OpenTelemetry's [semantic conventions for messaging spans](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/):
  span names and kinds, the creation context, links.
- IBM MQ's REST API v3, the destructive get and its `ibm-mq-usr` response header:
  [DELETE …/queue/{queueName}/message](https://ibm.com/support/knowledgecenter/SSFKSJ_9.3.0/refdev/q130930_.html).
- [Tempo's HTTP API](https://grafana.com/docs/tempo/latest/api_docs/);
  [VictoriaTraces](https://docs.victoriametrics.com/victoriatraces/).
- [psycopg's connection pool](https://www.psycopg.org/psycopg3/docs/advanced/pool.html), the
  `check` callback.
- The lab's own record: [reviews/R1.4.md](reviews/R1.4.md), `output/phase6-tracing.txt`,
  `output/trace-capture.txt`, `output/tracing-measurements.txt`, `output/r1-5-mq-measurements.txt`.

## Diagram sources

The two figures are drawn with diagram-kit, the telemetry layer in
[`diagrams/layers/source.html`](diagrams/layers/source.html) and the trace mock in
[`diagrams/r1-trace-mock/source.html`](diagrams/r1-trace-mock/source.html); their pages say how to
render them again. The screenshots are taken by `tests/trace_capture.py`, and change with the
numbers on this page.
