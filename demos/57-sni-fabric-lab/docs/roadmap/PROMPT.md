# The prompt that drives the roadmap

Give this to whoever (or whatever agent) builds the next release. It restates the decisions in
[ROADMAP.md](ROADMAP.md) as instructions.

You are extending demo 57, the SNI fabric lab (`demos/57-sni-fabric-lab`): a Compose lab on
Podman in which Envoy is the only path between any two components. Grow it into "Fabric
Coffee", told as five chapters (R1 observability foundation, R2 catalog and cart, R3 checkout
and payments, R4 business observability, R5 twelve-factor hardening), observability first.

Telemetry standards: the OpenTelemetry Collector (`otel/opentelemetry-collector-contrib`, the
newest release at least two weeks old) as the only pipeline. Metrics: VictoriaMetrics, with
Prometheus kept on the same scrape targets and parity-tested. Logs: VictoriaLogs. Traces:
Tempo 3 in single-binary mode as the standard (the trace stack Red Hat supports on OpenShift),
with the collector also sending every trace to VictoriaTraces for comparison (state its v0.x
caveat). Grafana with every datasource, the VictoriaLogs plugin baked in at build time.
Zero-code auto-instrumentation first (`opentelemetry-instrument`, `OTEL_*` env only); W3C
`traceparent` through Envoy's `mesh_http` and through IBM MQ; JSON logs with trace ids; RED
metrics from spans with exemplars; business metrics as first-class telemetry.

Rules: Envoy stays the only path (every new component on its own internal network, reached
through an Envoy alias); loopback-only ports; each component its own UID, keys and secrets;
pins at least two weeks old, hash-locked dependencies; no company identifiers; the 12 factors
as a scorecard with every gap closed by R5. Work in sprints of stories with Given/When/Then
acceptance criteria; mocks first (UI mocks approved and committed, service mocks with written
contracts and contract tests, a "what good looks like" trace mock). A story is done only when
its tests in `scripts/verify.sh` pass, `scripts/run.sh --fresh` passes, it emits traces,
metrics and logs that were queried in the real stores, the docs and the chapter page are
updated from measured numbers, and Codex and Cursor reviewed it. Research and measure before
building; retract any claim the data refutes; end each sprint with a review page and a retro.
