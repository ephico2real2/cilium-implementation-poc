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

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../diagrams/layers/telemetry.dark.png">
  <img alt="Signals pass Envoy twice: from telemetrygen to the collector through otlp.mesh, and from the collector to Tempo, VictoriaTraces, VictoriaMetrics and VictoriaLogs through their own aliases; Prometheus scrapes every component through Envoy; Grafana reads every store through Envoy." src="../diagrams/layers/telemetry.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*The telemetry layer. Solid is built and checked; dashed is sprint 2.*

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/collector-accepted-spans.dark.png">
  <img alt="Prometheus graph of otelcol_receiver_accepted_spans_total rising as telemetrygen's spans reach the collector through Envoy." src="../screenshots/sprint1/collector-accepted-spans.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

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
the trace ids), sent by `telemetrygen` through Envoy to the collector, then followed by hand in
the browser. Each picture is a step the walk script clicks; the script fails, rather than takes
the picture, when the step does not show what it should.

### 1. Grafana knows every store

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/02-datasources.dark.png">
  <img alt="Grafana's data sources page lists Prometheus, Tempo, VictoriaLogs, VictoriaMetrics and VictoriaTraces, each with an Envoy alias as its URL." src="../screenshots/sprint1/02-datasources.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Five data sources, every URL an Envoy alias (`*.mesh:18080`): Grafana reaches no store
directly.*

### 2. Each one answers its test

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/06-datasource-tempo.dark.png">
  <img alt="Tempo's data source page after clicking Test: Data source is working." src="../screenshots/sprint1/06-datasource-tempo.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*"Test" clicked on Tempo. The same for the other four: `03` to `07` in
[../screenshots/sprint1/](../screenshots/sprint1/).*

### 3. The run's traces in Tempo, and one opened

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/09-tempo-trace.dark.png">
  <img alt="Grafana Explore on Tempo: a TraceQL search for the run's service lists five traces; the clicked one opens with its root span lets-go and child span okey-dokey-0." src="../screenshots/sprint1/09-tempo-trace.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*TraceQL `{resource.service.name="walk-ab190b56"}` finds the run's 5 traces; clicking one opens
it: a root span and its child.*

### 4. The same trace in VictoriaTraces

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/10-victoriatraces-trace.dark.png">
  <img alt="Grafana Explore on VictoriaTraces through the Jaeger data source: the same trace id, the same two spans." src="../screenshots/sprint1/10-victoriatraces-trace.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*The collector sent the same trace to both stores; R1.3 compares them on every trace.*

### 5. The run's metrics in VictoriaMetrics

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/11-victoriametrics-metrics.dark.png">
  <img alt="Grafana Explore on VictoriaMetrics: the run's counter rising for two minutes." src="../screenshots/sprint1/11-victoriametrics-metrics.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Two minutes of OTLP metrics, stored with their dotted OpenTelemetry label names
(`service.name`).*

### 6. The run's log lines in VictoriaLogs, found by trace id

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/12-victorialogs-lines.dark.png">
  <img alt="Grafana Explore on VictoriaLogs: the query trace_id equals the run's trace id returns five lines." src="../screenshots/sprint1/12-victorialogs-lines.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Looked up by the trace id from step 3: the first sight of chapter 1's goal, a trace's logs one
query away. Sprint 2 makes the services write such lines themselves.*

### 7. Prometheus scrapes everything through Envoy

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../screenshots/sprint1/13-prometheus-targets.dark.png">
  <img alt="Prometheus target health: every job, including otel-collector, tempo, victoria-traces, victoria-metrics and victoria-logs, is up, each scraped at metrics.mesh:18080." src="../screenshots/sprint1/13-prometheus-targets.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Every target is `metrics.mesh:18080/metrics/<component>`: Prometheus, too, sees only Envoy.*

## Found by looking

The walk's pictures found what the checks had not: the VictoriaLogs plugin's settings page
showed `Unexpected token 'o', "not routed "... is not valid JSON`. Envoy's access log named the
request, `POST /select/tenant_ids`, a read the plugin makes that R1.2's route list did not allow;
Grafana's alerting view likewise asks VictoriaMetrics for `GET /api/v1/rules`. Both are read-only
and now routed; the pictures above were taken after the fix.

## Re-taking the pictures

```bash
python3 tests/sprint1_walk.py docs/screenshots/sprint1 <run> <trace-id>
```

`<run>` and `<trace-id>` are a telemetrygen service name and one of its trace ids, from a
`verify.sh phase6` run or sent by hand (see the script's header). The script needs Playwright
with Chromium.
