# Chapter 1 — "Turn the lights on" (in progress)

Release 1 gives Fabric Coffee its telemetry before any new feature: one OpenTelemetry Collector
as the only pipeline, traces in Tempo (and VictoriaTraces, compared), metrics in
VictoriaMetrics beside Prometheus, logs in VictoriaLogs. This page grows with each story; the
numbers come from the review records in [../reviews/](../reviews/), the pictures from
`tests/sprint1_walk.py`.

## Where we are

| Sprint | Story | Status | Built by, reviewed by | Record |
|---|---|---|---|---|
| 1 | R1.1 The collector is the one pipeline | done | Codex, OB3 | [R1.1](../reviews/R1.1.md) |
| 1 | R1.2 The stores are running | done | OB3, Codex | [R1.2](../reviews/R1.2.md) |
| 1 | R1.3 Side by side, compared | next | Codex, OB3 | — |
| 2 | R1.4–R1.9 One order, one story | not started; its two mocks await approval | — | [BACKLOG](../roadmap/BACKLOG.md) |

## Sprint 1, so far: the pipeline and the stores

Every signal reaches the collector only through Envoy (`otlp.mesh`), and the collector reaches
each store only through Envoy too; Envoy routes each store's write path, the read API Grafana
uses and its readiness probe, and nothing else.

![Signals pass Envoy twice: from telemetrygen to the collector through otlp.mesh, and from the collector to Tempo, VictoriaTraces, VictoriaMetrics and VictoriaLogs through their own aliases; Prometheus scrapes every component through Envoy; Grafana reads every store through Envoy.](../diagrams/layers/telemetry.light.png)

*The telemetry layer. Solid is built and checked; dashed is sprint 2.*

![Prometheus graph of otelcol_receiver_accepted_spans_total over an hour: steps up as runs arrive, two drops where the collector restarted.](../screenshots/sprint1/collector-accepted-spans.light.png)

*R1.1: the collector's own counter of accepted spans, scraped by Prometheus through Envoy,
over one hour of building (2026-10-21 23:25 to 2026-10-22 00:24 UTC): each step up is a
`phase6` or `telemetrygen` run arriving; each drop is the collector restarting, its counter
starting again from zero.*

| What was measured | Result |
|---|---|
| `verify.sh phase6` | 19 of 19: the collector, each store's readiness and metrics through Envoy, all five datasources, one run found in every store |
| One run's 5 traces | the same 5 trace ids in Tempo and VictoriaTraces |
| VictoriaTraces stopped for 3 min 40 s while traces were sent | all 5 delivered after it returned; the collector retried 57 times and dropped nothing |
| Envoy and the stores' admin and delete APIs | 29 of 29 route checks: refused with Envoy's own 404, reads allowed |
| Tempo 3.1 single binary | 25 ms to start, 32 MB idle, no Kafka |
| Memory in the 3887 MB Podman VM | 1255 MB still available with all four stores running |
| `scripts/run.sh --fresh`, everything from nothing | 7 min 52 s, 84 checks, 0 failures (`output/transcript.txt`, 2026-10-22) |

## The walk: one run, followed through every store

One named run (`walk-ab190b56`: 5 traces, 2 minutes of metrics, 5 log lines carrying one of
the trace ids), sent by `telemetrygen` through Envoy to the collector on 2026-10-22, on the lab
rebuilt from nothing, then followed in the browser by `tests/sprint1_walk.py`. Each picture is a
step the script clicks; it fails, rather than takes the picture, when the step does not show
what it should.

### 1. Sign in to Grafana

![Grafana's sign-in page with the user admin filled in and the password masked.](../screenshots/sprint1/01-grafana-login.light.png)

*Grafana's own sign-in form, user `admin` (the lab password is in `secrets/`, documented in
`docs/usage.md`). The anonymous viewer can read the dashboard but not Explore or data sources.*

### 2. Grafana knows every store

![Grafana's data sources page lists Prometheus, Tempo, VictoriaLogs, VictoriaMetrics and VictoriaTraces, each with an Envoy alias as its URL.](../screenshots/sprint1/02-datasources.light.png)

*Five data sources, every URL an Envoy alias (`*.mesh:18080`): Grafana reaches no store
directly.*

### 3. Each one answers its test

The data sources are provisioned from files, so Grafana offers **Test**, not "Save & test".

![Prometheus data source after Test: Successfully queried the Prometheus API.](../screenshots/sprint1/03-datasource-prometheus.light.png)

*Prometheus: "Successfully queried the Prometheus API", through `prometheus.mesh`.*

![VictoriaMetrics data source, of type Prometheus, after Test: Successfully queried the Prometheus API.](../screenshots/sprint1/04-datasource-victoriametrics.light.png)

*VictoriaMetrics answers the same Prometheus API, through `victoriametrics.mesh`.*

![VictoriaLogs data source after Test: Data source is working, with no error.](../screenshots/sprint1/05-datasource-victorialogs.light.png)

*VictoriaLogs, through the plugin baked into the Grafana image. Before the fix below, this page
also showed an error.*

![Tempo data source after Test: Data source is working.](../screenshots/sprint1/06-datasource-tempo.light.png)

*Tempo, through `tempo.mesh`.*

![VictoriaTraces, a Jaeger data source, after Test: Data source is working.](../screenshots/sprint1/07-datasource-victoriatraces.light.png)

*VictoriaTraces, read with Grafana's built-in Jaeger data source at
`victoriatraces.mesh:18080/select/jaeger`.*

### 4. The run's traces in Tempo

![Grafana Explore on Tempo: a TraceQL search for the run's service lists five traces.](../screenshots/sprint1/08-tempo-search.light.png)

*TraceQL `{resource.service.name="walk-ab190b56"}` finds the run's 5 traces.*

### 5. One trace opened, by clicking it

![The clicked trace opens beside the search: root span lets-go and its child okey-dokey-0.](../screenshots/sprint1/09-tempo-trace.light.png)

*Clicking a trace id opens it: telemetrygen's root span and its one child.*

### 6. The same trace in VictoriaTraces

![Grafana Explore on VictoriaTraces through the Jaeger data source: the same trace id, the same two spans.](../screenshots/sprint1/10-victoriatraces-trace.light.png)

*The collector sent the same trace to both stores; R1.3 compares them on every trace.*

### 7. The run's metrics in VictoriaMetrics

![Grafana Explore on VictoriaMetrics: the run's counter rising for two minutes.](../screenshots/sprint1/11-victoriametrics-metrics.light.png)

*Two minutes of OTLP metrics, one sample a second, stored with their dotted OpenTelemetry label
names (`service.name`).*

### 8. The run's log lines in VictoriaLogs, found by trace id

![Grafana Explore on VictoriaLogs: the query trace_id equals the run's trace id returns five lines.](../screenshots/sprint1/12-victorialogs-lines.light.png)

*Looked up by the trace id from step 5: the first sight of chapter 1's goal, a trace's logs one
query away. Sprint 2 makes the services write such lines themselves.*

### 9. Prometheus scrapes everything through Envoy

![Prometheus target health: all 11 jobs up, including otel-collector, tempo, victoria-traces, victoria-metrics and victoria-logs, each scraped at metrics.mesh:18080.](../screenshots/sprint1/13-prometheus-targets.light.png)

*All 11 targets up, each `metrics.mesh:18080/metrics/<component>`: Prometheus, too, sees only
Envoy.*

## Found by looking

The walk found what the checks and both reviews had not.

![Before the fix: the VictoriaLogs data source page shows an error, Unexpected token 'o', not routed is not valid JSON, above the Data source is working banner.](../screenshots/sprint1/found-victorialogs-not-routed.light.png)

*Before the fix (2026-10-22 01:21 UTC): the data source test passes, yet the page reports
`Unexpected token 'o', "not routed "... is not valid JSON`.*

Envoy's access log named the request: `POST /select/tenant_ids`, a read the plugin makes when
its settings page opens, which R1.2's route list did not allow; Envoy answered with its own
`not routed` text, which the plugin tried to parse as JSON. Grafana's alerting view likewise
asks VictoriaMetrics for `GET /api/v1/rules`. Both are read-only, and both are now routed, with
three route tests; step 3 above shows the page after the fix.

## Re-taking the pictures

```bash
python3 tests/sprint1_walk.py docs/screenshots/sprint1 <run> <trace-id>
```

`<run>` and `<trace-id>` are a telemetrygen service name and one of its trace ids, from a
`verify.sh phase6` run or sent by hand (see the script's header). The script needs Playwright
with Chromium.
