# Roadmap: "Fabric Coffee" grows up, observably

**Status:** approved by the operator 2026-10-21; R1.1 and R1.2 done 2026-10-22. Release 1's stories are in
[BACKLOG.md](BACKLOG.md), the prompt that drives the work in [PROMPT.md](PROMPT.md), and the story so far in
[../story/](../story/).

## Context

Demo 57 today proves one idea: Envoy as the only path, one TLS port routed on SNI, with orders,
IBM MQ, Postgres, a TCP service, metrics scraped through Envoy, retries and recovery
(65 checks, `scripts/run.sh --fresh`). The operator wants to grow it into a richer shop
(catalog, cart, checkout, payment gateways) that is **observable by construction**:
auto-instrumentation, structured logs, traces and metrics for both the system and the business
logic, through the **OpenTelemetry Collector** as the one pipeline, stored in the Victoria
family and Tempo, with Prometheus kept. The work is run as features with agile stories, a
Definition of Done, mocks first, the 12 factors as a scorecard, and a story told release by
release.

Decisions taken with the operator (2026-10-21):

| Signal | Standard | Alongside, compared | Why |
|---|---|---|---|
| Metrics | VictoriaMetrics v1.153.0 | Prometheus (kept, same scrape targets, parity-tested) | Operator's choice; VictoriaMetrics reads the same scrape config and takes OTLP |
| Logs | VictoriaLogs v1.53.0 | — | Operator's choice; OTLP logs in, LogsQL out |
| Traces | **Tempo v3.1.0, single binary** | VictoriaTraces v0.12.0 (the collector fans the same traces out to both) | Red Hat's supported OpenShift tracing stack is now the Tempo Operator with the OpenTelemetry Collector (Jaeger support ended 2025-11-03); Tempo 3.1's single binary needs no Kafka; VictoriaTraces is v0.x and "not ready for production use" by its own docs |
| Pipeline | `otel/opentelemetry-collector-contrib:0.162.0` | — | The latest at least two weeks old (0.163.2 came out 2026-10-21; move to it after 2026-11-04). The operator's `quay.io/ephico2real/...` mirror was an example only |

Order: **observability first.** Release 1 instruments today's app, so every later feature is
born observable and the story shows each feature through its telemetry.

## Facts verified for this plan (2026-10-21)

| Fact | Source |
|---|---|
| Collector releases: v0.163.2 2026-10-21, v0.163.0/.1 2026-10-16, **v0.162.0 2026-09-29**; the repo's demos 10, 22, 23 pin 0.160.0 | `gh release list`, Docker Hub, `git grep` |
| Tempo releases: v3.1.1 and v3.0.5 2026-10-21, **v3.1.0 2026-09-29**; demo 21 ran `grafana/tempo:2.9.0` | `gh release list`, demo 21 evidence |
| Tempo 3.0 replaced ingesters ("Project Rhythm"); microservices mode needs a Kafka-compatible bus; **monolithic mode pushes in-process to the live-store without Kafka**; TraceQL metrics are GA | Tempo 3.0 release notes and migration guide |
| Red Hat: Jaeger-based tracing platform 3.5 was the last supported, support ended 2025-11-03; migrate to the Red Hat build of OpenTelemetry and the Tempo Operator | Red Hat distributed tracing release notes |
| VictoriaMetrics takes OTLP metrics at `/opentelemetry/v1/metrics`; Prometheus-compatible scraping | docs.victoriametrics.com |
| VictoriaMetrics exemplar support was added and **reverted in 2024**; no source found that it returned | VictoriaMetrics commit history (mirror) |
| VictoriaLogs takes OTLP logs at `/insert/opentelemetry/v1/logs` (:9428); Grafana plugin `victoriametrics-logs-datasource` v0.32.0 | docs, grafana.com, GitHub releases |
| VictoriaTraces takes OTLP traces at `/insert/opentelemetry/v1/traces` (:10428); Grafana reads it with the built-in Jaeger datasource | docs |
| Envoy v1.36.11's OpenTelemetry tracer reads the W3C `traceparent` header; exports over gRPC or HTTP | Envoy source, `span_context_extractor.cc` |
| OTel Python: SDK and OTLP exporter 1.45.1, instrumentations and `opentelemetry-distro` 0.66b1 (2026-10-06) | PyPI |
| The lab's networks have no internet: Grafana cannot fetch the VictoriaLogs plugin at runtime, so it is baked into a `localhost/fabric-grafana` image at build time | lab design |
| `edge_sni` passes TLS through, so Envoy cannot trace browser or MQ traffic; Envoy spans exist only on `mesh_http` | lab design |

## The story: one coffee shop, five chapters

Each release is a chapter, demoed at its end (a sprint review with screenshots in
`docs/story/NN-<chapter>.md`):

| Ch. | Release | Headline | What a reader sees |
|---|---|---|---|
| 0 | today | "The counter works" | Orders flow through Envoy; we can count them, not explain them |
| 1 | R1 Observability foundation | "Turn the lights on" | One order becomes one trace across API → Postgres → MQ → worker, in Tempo and VictoriaTraces; its logs share the trace id; a latency spike links to its trace |
| 2 | R2 Catalog and cart | "Customers browse" | A cart survives a restart (state in a backing service); we see which products are viewed, added, abandoned |
| 3 | R3 Checkout and payments | "Customers pay" | Card payments through a mock gateway with real failure modes; retries never charge twice |
| 4 | R4 Business observability | "We run the shop on data" | Revenue, conversion funnel, payment-success SLO with burn-rate alerts; a red SLO opens onto the failing traces |
| 5 | R5 Twelve-factor hardening | "Ready to leave the laptop" | The scorecard all green; a Kubernetes/OpenShift mapping (Tempo Operator, Red Hat build of OpenTelemetry) |

## Releases, epics and stories

Each story is INVEST-sized, with **acceptance criteria (Given / When / Then)**, a test in a new
`scripts/verify.sh` phase per release, and the telemetry it must emit.

### R1 — Observability foundation (2 sprints)

| Story | Acceptance (abridged) |
|---|---|
| R1.1 Collector as the one pipeline | Given every service, when it emits OTLP, then it reaches the collector only through Envoy (`otlp.mesh` on `mesh_http`, HTTP :4318; gRPC :4317 on a new L4 route), and the collector's own metrics are scraped |
| R1.2 Stores running | Tempo (single binary), VictoriaTraces, VictoriaMetrics, VictoriaLogs up, each on its own internal network, reached only through Envoy; Grafana datasources for all, with the VictoriaLogs plugin baked in |
| R1.3 Side by side, compared | Prometheus remote-writes its scraped samples to VictoriaMetrics and a parity test compares 10 panel queries; the same trace id is found in Tempo and in VictoriaTraces |
| R1.4 Zero-code auto-instrumentation | orders-api, worker and tcp-svc start under `opentelemetry-instrument`; FastAPI, httpx, psycopg spans appear with no code change; configuration is `OTEL_*` env vars only (factor III) |
| R1.5 Trace across MQ | `traceparent` travels with the order event (spike: MQ REST v3 user properties, `ibm-mq-usr`; fallback: a field in the JSON body), so the worker's span joins the order's trace |
| R1.6 Envoy spans on the mesh | `mesh_http` emits spans to the collector; a trace shows the Envoy hops between services and retries as separate attempts |
| R1.7 Structured logs with trace ids | Every log line is JSON with `trace_id` and `span_id`, sent as OTLP logs to VictoriaLogs; from a span in Grafana, "logs for this span" opens the matching lines (spike: Tempo's trace-to-logs with the VictoriaLogs datasource) |
| R1.8 Metrics ↔ traces | RED metrics per service from Tempo's metrics generator (or the collector's `spanmetrics` connector); exemplars kept by Prometheus (exemplar storage on) link a latency spike to its Tempo trace; VictoriaMetrics correlates by shared labels |
| R1.9 Telemetry dashboard | A second dashboard via diagram-kit `/dashboard` (inventory first): pipeline health (accepted, refused, dropped), RED per service, log volume by level |

### R2 — Catalog and cart (1–2 sprints)

| Story | Acceptance (abridged) |
|---|---|
| R2.1 Catalog service | `catalog` lists products with prices and stock; the Orders page becomes a shop page, from an approved mock |
| R2.2 Cart service | `cart` keeps a cart per session in **Valkey**, a new backing service attached through a new Envoy TCP listener `mesh_kv`; a cart survives restarting `cart` (factor VI) |
| R2.3 Cart telemetry | Viewed, added, removed, abandoned as span events and metrics, on the R1 dashboard |

### R3 — Checkout and payments (2 sprints)

| Story | Acceptance (abridged) |
|---|---|
| R3.1 Payment gateway mock | `payment-gateway-mock` with deterministic test cards (approve, decline, insufficient funds, timeout, 3-D Secure challenge, duplicate), latency and error controls, signed webhooks; contract in `docs/mocks/payment-gateway.md` |
| R3.2 Checkout orchestration | `checkout` turns a cart into an order: reserve stock → authorise → place order → capture; any failure undoes the earlier steps (a saga, each step idempotent) |
| R3.3 Never charge twice | One Idempotency-Key from browser to gateway; with chaos at 50%, charges equal paid orders |
| R3.4 Second gateway | A second mock provider behind the same interface, chosen by config (factor IV) |
| R3.5 Payment telemetry | Authorisations, declines by reason, gateway latency, webhook lag: metrics, spans, logs |

### R4 — Business observability (1 sprint)

| Story | Acceptance (abridged) |
|---|---|
| R4.1 Business KPIs | Revenue per minute, average order value, the funnel view → cart → checkout → paid |
| R4.2 SLOs and alerts | Checkout availability and payment latency SLOs; `vmalert` burn-rate rules; alert → dashboard → trace in three clicks |
| R4.3 The admin portal tells the story | Portal panels for KPIs and SLOs, read through the API |

### R5 — Twelve-factor hardening (1 sprint)

Closes every scorecard gap; adds `docs/kubernetes-observability.md` mapping the stack to
OpenShift (Tempo Operator, Red Hat build of OpenTelemetry) and to plain Kubernetes, verified at
that time.

## The 12 factors as a scorecard

| Factor | Today | Gap | Closed in |
|---|---|---|---|
| I Codebase | one repo, one demo folder | — | — |
| II Dependencies | hash-locked Python, pinned images | Grafana plugin pinned at build | R1 |
| III Config | env vars and secrets files | some names fixed in code (`QM1`, queues); `OTEL_*` to add | R1, R5 |
| IV Backing services | Postgres and MQ as attached resources through Envoy aliases | Valkey and gateways the same way; gateway swap by config | R2, R3 |
| V Build, release, run | `compose up --build`, `:dev` tags | versioned release tags and a release manifest | R5 |
| VI Processes | stateless except orders-api's chaos switch in memory | cart in Valkey; chaos state in a backing service | R2, R5 |
| VII Port binding | each service binds its own port | — | — |
| VIII Concurrency | one of each | `--scale orders-api=2` behind Envoy, proven | R5 |
| IX Disposability | graceful stop, start-up retries, sweeper | MQ starts in about 2 min under emulation: documented, not fixable here | R5 |
| X Dev/prod parity | same images; Compose here, Kubernetes later | Kubernetes/OpenShift notes for every component | R5 |
| XI Logs | JSON to stdout | also OTLP to VictoriaLogs, with trace ids | R1 |
| XII Admin processes | schema applied at API start | a one-off `migrate` job; admin tasks as `compose run` | R5 |

## Mocks first

- **UI mocks:** before each feature's code, a static HTML mock (shop page, cart, checkout, the
  portal's observability panels) is walked in a browser, approved by the operator, and
  committed as `docs/design/<name>-mock.html` with a screenshot.
- **Service mocks:** `payment-gateway-mock` (R3.1) and a second provider (R3.4), each with a
  written contract (`docs/mocks/*.md`: endpoints, test cards, webhook signing, failure
  switches) and contract tests run against the mock.
- **Telemetry mock:** a "what good looks like" diagram-kit figure of one order's expected span
  tree, drawn before R1.4–R1.6 and compared with the real trace afterwards.

## Ways of working

- **Sprints** of one to two sessions: a sprint goal (a chapter or half of one), a review page
  (`docs/story/NN-*.md`: what changed, screenshots, measured numbers) and a short retro.
- **Definition of Ready:** acceptance criteria written; the mock, if any, approved; the facts it
  relies on verified (versions, endpoints); its test named.
- **Definition of Done (story):**
  1. Code, config and docs in one change; no placeholder or dead code; lint and shellcheck
     clean; pins at least two weeks old.
  2. Its acceptance tests in `scripts/verify.sh` pass; `scripts/run.sh --fresh` passes from
     nothing, and `scripts/run.sh` over the existing lab (the upgrade path) passes too.
     **Nothing existing stops:** every check that passed in the committed `output/transcript.txt`
     passes in the new one (`tests/scripts/test_checks_kept.sh`); a check is loosened only when
     its stricter form is measured failing on a healthy lab, the measurement in `docs/reviews/`.
  3. It emits traces, metrics and JSON logs with trace ids; every new query is run against the
     real stores (dashboard skill §1 and §9).
  4. Envoy is still the only path: the isolation checks pass for every new component.
  5. Security unchanged or better: loopback-only ports, own UID, keys and secrets, no company
     identifiers, lab credentials documented.
  6. Docs updated (usage, README record, RECAP, the chapter page), numbers from the transcript;
     `tests/scripts/test_recap_counts.sh` passes.
  7. Reviewed in two passes by two seats that did not write it (Codex and OB3 by default): every
     finding comes with its full fix and a test that fails before and passes after, every
     decision is written in `docs/reviews/`, and the second pass runs on the fixed head. `main`
     is protected, so it goes in through a pull request the operator merges.
  8. Anything a user can see is walked in the browser by a script (`tests/browser_flows.py`,
     `tests/sprint1_walk.py` and their successors), captured in both themes; the documents
     embed the light capture, each with a caption saying what it shows. The walk is part of the
     test: in sprint 1 it found an Envoy route that no check and no review had.
  9. A newcomer can follow it: RECAP's glossary, prerequisites and troubleshooting cover what
     the story adds, and every command added to a document has been run as written.
  10. Once E1 lands: CI is green on the pull request.
- **Definition of Done (release):** all its stories done; the chapter demoed; memory measured.

## Risks and spikes

| Item | Plan |
|---|---|
| Memory: Prometheus, VictoriaMetrics, VictoriaLogs, Tempo, VictoriaTraces and the collector | Measure after R1.2. The VM has 4 GiB and about 1.5 GB free today; resizing it restarts it and the `secure-notes` containers, so it needs the operator's go-ahead |
| Tempo 3 single-binary configuration in the lab | Spike at R1.2: smallest monolithic config with local storage, measured |
| Trace-to-logs from Tempo to VictoriaLogs in Grafana | Spike at R1.7; fallback: a link built from the trace id |
| Exemplars | From Prometheus (exemplar storage) and Tempo; VictoriaMetrics' exemplar status is a spike (reverted in 2024) |
| Trace context through MQ REST | Spike at R1.5; fallback: a field in the event body |
| Collector 0.162.0 vs the repo's 0.160.0 | Use 0.162.0 here; note it in the docs; move to 0.163.x after 2026-11-04 |
| Browser spans | Out of scope for R1 (edge TLS is passed through); later: OpenTelemetry JS in the pages |

## Next steps

1. Write the roadmap into the demo: `docs/roadmap/ROADMAP.md` (this plan),
   `docs/roadmap/PROMPT.md` (the prompt below), `docs/roadmap/BACKLOG.md` (R1's stories with
   full acceptance criteria), `docs/story/00-the-counter.md` (chapter 0 from today's numbers).
2. Draw the R1 telemetry mock (expected span tree) and the portal's observability-panel mock,
   and get them approved.
3. Start Sprint 1 (R1.1–R1.3) only on the operator's go.

Step 1 adds files under `demos/57-sni-fabric-lab/docs/roadmap/` and `docs/story/`, and a link
from `README.md` and `RECAP.md` ("What's next"). Nothing is committed or pushed without the
operator's word.

## Verification

- Every fact above was checked this session, with its command or source.
- Each release has a concrete exit test: R1, one order's trace spans every service in both
  Tempo and VictoriaTraces, with matching logs and an exemplar link; R2, a cart survives a
  restart; R3, under chaos at 50% charges equal paid orders; R4, a burn-rate alert fires under
  injected failures and leads to the traces; R5, the scorecard is green and
  `--scale orders-api=2` passes `verify.sh`.
