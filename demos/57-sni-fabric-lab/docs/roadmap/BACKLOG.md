# Backlog: Release 1, "Turn the lights on"

Release 1 instruments today's lab before any feature is added: one OpenTelemetry Collector as
the only pipeline, the stores chosen in [ROADMAP.md](ROADMAP.md), zero-code
auto-instrumentation, traces across Envoy and IBM MQ, logs with trace ids, and metrics linked
to traces. Each story below is written to be ready: who it is for, acceptance criteria as
Given / When / Then, the test that proves it (a check in a new `scripts/verify.sh` phase,
`phase6`), the telemetry it must emit, and what is still open.

## Sprints

| Sprint | Goal | Stories |
|---|---|---|
| 1 | "The pipeline and the stores": every store up behind Envoy, fed by the collector, compared side by side | R1.1 (done), R1.2 (done), R1.3, E1 |
| 2 | "One order, one story": an order's trace, logs and metrics, linked | R1.4, R1.5, R1.6, R1.7, R1.8, R1.9 |

**Every story is an enhancement: nothing that works today stops.** Each one carries the
acceptance criterion "Nothing existing stops" below, on top of its own, and the Definition of
Done in [ROADMAP.md](ROADMAP.md) ("Ways of working") applies to all of them.

| Given | When | Then |
|---|---|---|
| the lab as it was before the story | the story's change is applied | `scripts/run.sh --fresh` passes, `scripts/run.sh` over the existing lab (the upgrade path) passes, and every check that passed in the committed `output/transcript.txt` passes in the new one (`tests/scripts/test_checks_kept.sh <old> <new>`), so the count of checks only grows; a check's condition is loosened only when its stricter form is measured failing on a healthy lab, the measurement recorded in `docs/reviews/` (as PR88's "rose by 2": exactly 2 became at least 2) |

Before sprint 2, both mocks approved by the operator:

- the span tree one order must produce: `docs/diagrams/r1-trace-mock/` (page, light and dark
  PNGs);
- the admin portal's Telemetry page: `docs/design/portal-telemetry-mock.html` (with light, dark
  and 375-px captures beside it).

## R1.1 The collector is the one pipeline

As the person running the lab, I want every signal to leave each service through one
OpenTelemetry Collector, so that a store can be added or swapped without touching any service.

| # | Given | When | Then |
|---|---|---|---|
| 1 | the lab is up | a service sends a span to `http://otlp.mesh:18080` | the collector accepts it (`otelcol_receiver_accepted_spans_total` rises) |
| 2 | the collector's network | anything but Envoy is dialled from it | the name does not resolve (isolation, as in phases 1–3) |
| 3 | the collector is restarted | services keep sending | no request in the lab fails; the SDKs retry and their queues drain |
| 4 | the collector runs | Prometheus scrapes and remote-writes to VictoriaMetrics | its own metrics arrive through `metrics.mesh/metrics/otel-collector` and are held by both metric stores |

- **Test:** `phase6` checks "otel: a span reaches the collector through Envoy", "isolation:
  the collector shares a network only with Envoy", and "metrics: the collector's own metrics
  through mesh_http".
- **AC 3 timing:** "the collector is restarted while services send" is measured in sprint 2,
  once services send, because nothing sends OTLP in sprint 1 except `telemetrygen`.
- **Image:** `otel/opentelemetry-collector-contrib:0.162.0`.
- **Open:** OTLP over HTTP on `mesh_http` is the plan; gRPC needs an L4 route and is added only
  if a source cannot send HTTP (Envoy's own tracer can send either).

## R1.2 The stores are running

As a reader of the lab, I want Tempo, VictoriaTraces, VictoriaMetrics and VictoriaLogs running
the same way as everything else, so that the telemetry stack obeys the lab's own rules.

| # | Given | When | Then |
|---|---|---|---|
| 1 | `scripts/run.sh --fresh` | it finishes | Tempo v3.1.0 (single binary), VictoriaTraces v0.12.0, VictoriaMetrics v1.153.0 and VictoriaLogs v1.53.0 are healthy |
| 2 | each store | it is reached | only through an Envoy alias; it has its own internal network |
| 3 | Grafana | its API tests each datasource | Prometheus, VictoriaMetrics, VictoriaLogs (plugin v0.32.0, baked into `localhost/fabric-grafana`), Tempo, and VictoriaTraces (Jaeger datasource) all answer OK |
| 4 | the lab after R1.2 | memory is measured | the free memory in the Podman VM is recorded; under 500 MB stops the sprint for the operator's decision on resizing |

- **Test:** `phase6` checks one per store and one per datasource.
- **Spike first:** the smallest Tempo 3.1 monolithic configuration with local storage,
  measured (memory, start time).
- **Status (2026-10-22): done.** Reviewed in two passes by Codex and OB3 with the whole demo
  (decisions: [../reviews/R1.2.md](../reviews/R1.2.md) and
  [../reviews/PR88.md](../reviews/PR88.md)); `scripts/run.sh --fresh` passes, 8 min 6 s, 84
  checks. As first measured, on the running lab:
  - Spike: `observability/tempo.yaml` (OTLP HTTP in, query API on 3200, local storage, usage
    report off) starts in 25 ms from container start to "Tempo started", read-only root, as
    UID 10004; 31.7 MB idle, 52.5 MB after six spans and a few queries; a trace id sent is
    found by search and by `/api/v2/traces/<id>` (an unknown id answers 200 with an empty
    trace, so checks count spans, not status codes).
  - AC 1–2: all four stores ready through Envoy and each on its own internal network shared
    with Envoy alone; only VictoriaMetrics' image has a tool for a Compose health check
    (`wget`), the other three are distroless.
  - AC 3: Grafana's test of all five datasources answers OK; the VictoriaLogs plugin v0.32.0
    is signed (`signature: valid`, offline); the image build fails on a checksum mismatch.
  - End to end: one run's five trace ids are the same in Tempo and VictoriaTraces (after
    27 s), its five metric samples are in VictoriaMetrics (30 s), its five log lines in
    VictoriaLogs (3 s). With VictoriaTraces stopped, exactly its four checks fail, and the
    collector's retries deliver the held traces once it is back.
  - `phase6`: 19 checks, failures 0, 1 min 49 s; phases 1–3: failures 0.
  - AC 4, memory: the Podman VM (3887 MB) has **1115 MB available** at the lowest of three
    samples with everything running (1115 to 1277 MB; 1328 MB before R1.2). The stores use
    Tempo 68 to 157 MB, VictoriaMetrics 37 to 44 MB, VictoriaTraces 14 to 19 MB,
    VictoriaLogs 13 to 17 MB; Grafana grew from 110 MB to 200 to 310 MB with the plugin's
    backend. Above the 500 MB floor: no resize needed.
  - `scripts/run.sh --fresh` ran after the review fixes: 84 checks, 0 failures
    (`output/transcript.txt`).

## R1.3 Side by side, compared

As the person choosing the standard, I want Prometheus and VictoriaMetrics, and Tempo and
VictoriaTraces, fed the same data and compared, so that the choice rests on measurements.

| # | Given | When | Then |
|---|---|---|---|
| 1 | Prometheus and VictoriaMetrics with the same samples | ten of the dashboard's queries run on both | each pair agrees within the envelope `tests/parity.py` derives from both engines' `rate` (recorded table) |
| 2 | one trace sent through the collector | it is looked up by id | it is found in Tempo and in VictoriaTraces with the same span count |
| 3 | the existing dashboard | its datasource is switched to VictoriaMetrics | every panel still draws (`tests/dashboard_queries.py --prometheus <vm>` passes) |
| 4 | Prometheus feeds the dashboard today | R1.3 lands | Prometheus stays the dashboard's default; VictoriaMetrics is a choice beside it, nothing is replaced |
| 5 | MQ's exporter consumes queue-manager gauges on read | both metric stores need the same samples | Prometheus remains the one scraper and remote-writes every sample through Envoy's mesh-only `victoriametrics.mesh/api/v1/write` route; VictoriaMetrics runs no scraper, while its `net-vmetrics` isolation stays unchanged |
| 6 | metrics that arrive over OTLP keep OpenTelemetry's dotted label names in VictoriaMetrics (`service.name`, measured in R1.2) | the parity table is written | it compares the scraped series, which share Prometheus's names, and states what was left out and why |

- **Test:** `tests/parity.py` (new), and `phase6` checks for the trace lookup.
- **Seats:** Codex builds (Podman through the machine socket); OB3 and OB1-lite review, and a
  second pass on the fixed head.
- **Pictures:** the parity table and the dashboard on each datasource, added to chapter 1.
- **Status (2026-10-22): built in two rounds, measured on the live lab, first review pass applied.**
  - AC 5: with two scrapers, Prometheus's MQ scrape fell from 136 samples to 108 and lost all
    28 `ibmmq_qmgr_*` publication gauges; two back-to-back reads returned the recovery-log
    latency gauge once, then not at all. In `github.com/ibm-messaging/mq-container` under
    `internal/metrics`, `exporter.go` resets and refills gauge vectors from publications cached
    since the previous collect, and `update.go` clears that cache. Prometheus is therefore the
    one scraper and remote-writes through Envoy. The measured temporary design gave both stores
    136 MQ samples and the gauge after six minutes, with remote-write rows rising and
    VictoriaMetrics `promscrape` at zero. `promtool` validates the committed config and rejects
    a malformed `remote_write` negative control.
  - AC 1 and AC 6: `tests/parity.py` selects ten queries by exact panel title and compares both
    stores at one timestamp, excluding OTLP-only dotted labels. A VictoriaMetrics rate must equal
    Prometheus's rate at T with only `rate`'s range widened to [310s], which is the exact
    MetricsQL value for the same regular samples. Values from T − s or T + s are different
    windows and cannot excuse a stale or damaged copy. It runs before phase 5's outages, after a
    complete `up` window and once every selected rate is exactly comparable. On the recorded
    fresh run the older sample-count gate waited for MQ's counter and all ten then agreed
    (`output/transcript.txt`).
  - AC 2: live trace `1763fe65af3432a70272b596b16f4eac` had two spans in each store. Tempo
    returned them under `trace.resourceSpans[].scopeSpans[].spans[]`; VictoriaTraces returned
    them under `data[].spans[]`. Phase 6 now requires 2 and 2, not merely equal counts.
  - AC 3 and AC 4: Grafana has one Prometheus datasource variable, defaults to uid
    `prometheus`, and every panel follows it. The Perses converter degraded the variable to an
    empty `variables` list and its supplied fixed `prometheus` datasource; its JSON was not
    hand-edited. On VictoriaMetrics: `31 queries, 0 with errors or warnings, 2 empty` before
    phase 5 generated the status-update failure series (`output/transcript.txt`).
  - Phase 6 now requires all 11 healthy metric jobs in both stores, the same positive count of
    fresh MQ recovery-log gauges and the same positive MQ scrape sample count. `run.sh` gates
    parity until every selected rate is comparable and fails a disagreement seen twice; it also recreates any running
    service whose bind-mounted source is newer than its container.
  - Measured after the second review pass (exact comparison): `scripts/run.sh --fresh` 11 min
    3 s, 87 checks, 0 failures, `84 before, 87 after`; parity waited 3 min 20 s for the two
    counters that first appear during phases 1-3 to hold a full window, then 10 of 10. The
    upgrade path passed every phase in 5 min 19 s, parity 10 of 10 on its first check.
  - Measured after the first review pass: `scripts/run.sh --fresh` 8 min 54 s, 87 checks, 0
    failures; checks kept `84 before, 87 after`; the route test 0 mismatches. The upgrade path
    over the running lab passed every phase in 5 min 18 s, parity 10 of 10 on the first read.
    Before the review, the upgrade path recreated exactly Grafana (its dashboards directory)
    and Prometheus (`prometheus.yml`), and parity disagreed on 2 of 10 on its first read: the
    reviewers traced it to the old gate, which opened while VictoriaMetrics' window still began
    before a gap (see `docs/reviews/R1.3.md`).

## E1 CI checks demo 57 on every pull request

An enhancement to the way the lab is built, not to the shop. As the operator who merges every
change, I want each pull request that touches demo 57 checked by CI before I look at it, so
that the regressions two reviews kept finding are caught by a machine on every change.

| # | Given | When | Then |
|---|---|---|---|
| 1 | a pull request that changes `demos/57-sni-fabric-lab/**` | it is opened or updated | a workflow runs shellcheck on every script, `mdfmt check` on the demo's Markdown (it needs markdownlint-cli2), `compose config`, Envoy's `--mode validate`, the collector's `validate`, the diagram-kit check of the demo's diagram pages, and the tests that need nothing running: `tests/scripts/test_verify_false_pass.sh`, `tests/scripts/test_run_sh.sh`, `tests/scripts/test_recap_counts.sh`, `tests/scripts/test_checks_kept.sh`, `tests/r1-1/test_collector_ports.sh`, `tests/r1-1/test_phase6.sh`, `tests/r1-1/test_usage_docs.sh` and `tests/test_dashboard.py` |
| 2 | any of them fails | the workflow finishes | the pull request's check is red and its log names the failing step |
| 3 | the tests that need a container engine and the lab's images but start nothing of the lab's (`tests/r1-1/test_compose_collector.sh`, `tests/scripts/test_key_isolation.py`, `tests/scripts/test_status_auth.sh`, `tests/scripts/test_prometheus_baseline.sh`, `tests/r1-2/test_plugin_checksum.sh`), and those that need the running lab (the `verify.sh` phases, `tests/r1-2/test_store_routes.sh`, `tests/dashboard_queries.py`, `tests/browser_flows.py`, `tests/grafana_capture.py`, `tests/sprint1_walk.py`) | the workflow is read | its header lists each with the command that runs it; a spike runs each of the first group on a GitHub runner (Podman, image builds, the plugin download), and every one that passes there moves into AC 1 |
| 4 | the repository's other workflows | E1 lands | they are unchanged; the new one runs only on demo 57's paths |
| 5 | the actions it uses | they are pinned | each by the full commit SHA of its release tag, the tag in a comment (a tag can be moved, a commit cannot); stricter than the repository's other workflows, which pin major tags and stay as they are (AC 4); it needs no secret |

- **Test:** the workflow on this story's pull request is green; on a throwaway branch that
  breaks one check on purpose (a substring comparison put back in `verify.sh`), it is red and
  names the step. Run time recorded.
- **Seats:** OB3 builds; Codex and OB1-lite review.

## Closing sprint 1

When R1.3 and E1 are done: the chapter 1 page gets the sprint's review (what changed, the
measured numbers, the pictures), a short retro (what helped, what hurt, one change for sprint
2), memory measured with everything running, and `scripts/run.sh --fresh` once more. Then
sprint 2 starts only on the operator's go, with its two mocks approved.

## R1.4 Zero-code auto-instrumentation

As a developer, I want spans from the services without editing their code, so that
instrumentation is a deployment choice, not a code change (factor III).

| # | Given | When | Then |
|---|---|---|---|
| 1 | orders-api, worker and tcp-svc | they start | under `opentelemetry-instrument`, configured only by `OTEL_*` environment variables |
| 2 | an order is placed | its trace is opened in Tempo | it holds FastAPI server spans, httpx client spans and psycopg spans |
| 3 | every span | its resource is read | `service.name`, `service.version` and `deployment.environment=lab` are set |
| 4 | the change | its diff is read | no file under `services/*/app` or the service modules changed for this story |

- **Test:** `phase6` "otel: one order's trace has server, client and database spans".
- **Pins:** OTel Python SDK 1.45.1, instrumentations 0.66b1, hash-locked.

## R1.5 The trace crosses IBM MQ

As someone following an order, I want the worker's work to sit in the same trace as the API
call that created the event, so that one order is one trace.

| # | Given | When | Then |
|---|---|---|---|
| 1 | an order is placed | the worker processes its event | the worker's span has the API span's trace id |
| 2 | the event is requeued after a failure | it is processed later | the later attempt joins the same trace (a span link or child) |

- **Test:** `phase6` "otel: the worker's span joins the order's trace".
- **Spike first:** does the MQ REST v3 user-property header (`ibm-mq-usr`) carry `traceparent`
  on put and return it on get? Fallback: a `traceparent` field in the event body.

## R1.6 Envoy's spans on the mesh

As someone debugging a slow call, I want Envoy's own spans between services, so that time spent
in the fabric is visible.

| # | Given | When | Then |
|---|---|---|---|
| 1 | a call on `mesh_http` | its trace is opened | an Envoy span sits between the caller's client span and the callee's server span |
| 2 | chaos at 50% | a retried status update is traced | the failed and the successful attempts are both visible |
| 3 | `edge_sni` | the documentation is read | it states that pass-through TLS cannot be traced by Envoy |

- **Test:** `phase6` "otel: Envoy spans on mesh_http"; the retry check under chaos.
- **Open:** whether Envoy draws one span per upstream attempt by default, or needs its upstream
  span option: measured, not assumed.

## R1.7 Structured logs with trace ids

As someone reading a trace, I want the log lines written during each span one click away, so
that I never grep three containers by hand again.

| # | Given | When | Then |
|---|---|---|---|
| 1 | any service | it logs inside a span | the line is JSON with `trace_id` and `span_id` |
| 2 | those lines | VictoriaLogs is queried by trace id | they come back, from every service the trace crossed |
| 3 | a span in Grafana | "logs for this span" is opened | the matching lines show |

- **Test:** `phase6` "logs: one order's trace id finds lines from orders-api and worker".
- **Spike:** Tempo's trace-to-logs link with the VictoriaLogs datasource; fallback: a link
  built from the trace id.

## R1.8 Metrics linked to traces

As someone on call, I want a latency spike to lead to an example trace, so that a graph turns
into an explanation.

| # | Given | When | Then |
|---|---|---|---|
| 1 | traffic from `scripts/load.py` | RED metrics are queried | rate, errors and duration per service exist in Prometheus and VictoriaMetrics (from spans) |
| 2 | Prometheus with exemplar storage on | a duration panel is drawn | it shows exemplars whose trace ids open in Tempo |
| 3 | VictoriaMetrics | the same panel is drawn | it correlates by shared labels (`service.name`, time); its exemplar status is recorded from a measurement |

- **Test:** `phase6` "metrics: exemplar trace id resolves in Tempo".

## R1.9 The telemetry dashboard

As anyone looking at the lab, I want one dashboard for the pipeline and the services' RED
metrics, built the same way as the first.

| # | Given | When | Then |
|---|---|---|---|
| 1 | the new metrics | the dashboard is designed | a metrics inventory comes first and the choices are recorded (diagram-kit `/dashboard`) |
| 2 | the dashboard | its tests run | every query returns, both forms (Grafana and Perses) agree, captures in both themes show no "No data" |

## Release exit test

One `scripts/load.py` run, then: a single order's trace spans orders-api, Postgres, MQ (put
and get), the worker and Envoy's mesh hops, in Tempo and in VictoriaTraces; its logs come back
from VictoriaLogs by trace id; a duration exemplar opens that kind of trace; and
`scripts/run.sh --fresh` passes with the new phase.
