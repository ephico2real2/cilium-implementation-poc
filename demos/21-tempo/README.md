# Demo 21 — Grafana Tempo: from a Hubble exemplar to the full trace, with Cilium doing the header work

**Where this sits in the whole:** [OBSERVABILITY-ARCHITECTURE.md](../../OBSERVABILITY-ARCHITECTURE.md) — the one picture of metrics, traces and flows across poc1, poc2 … poc-N, reviewed against what is deployed.

## Summary context

The pipeline this demo builds is the one from Isovalent's *Hubble and Grafana* post:

```
[ Application ]      ─▶ exports tracing headers (OpenTelemetry)          the petclinic JVMs + the Java agent (demo 20)
[ Cilium / Hubble ]  ─▶ extracts Trace IDs from HTTP headers, no sidecar  httpV2 exemplars, on ports behind the L7 proxy
[ Prometheus ]       ─▶ scrapes Hubble L7 metrics with Trace-ID exemplars demo 16 (exemplar-storage on since Section A)
[ Grafana ]          ─▶ shows the metric; the user clicks an exemplar dot  exemplarTraceIdDestinations → Tempo
[ Grafana Tempo ]    ─▶ shows the distributed trace timeline              this demo
```

Demo 16 had everything down to Prometheus and proved exemplars exist (Part 8) but had no trace
store: an exemplar was a 32-hex string and nothing more. Demo 18 and 20 produced the traces and
printed them to a log. This demo closes the loop. Every command is recorded in
[`output/transcript.txt`](output/transcript.txt); the browser captures are in
[`output/screenshots/`](output/screenshots/).

## Part 1 — Tempo, single binary, next to the stack

[`values-tempo.yaml`](values-tempo.yaml): chart `grafana/tempo` 1.24.4 (Tempo 2.9.0), OTLP receivers,
24 h retention, 256–512 Mi, no persistence (a pod restart loses a day of lab traces — nothing to tidy).

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
helm install tempo grafana/tempo --version 1.24.4 -n monitoring --kube-context kind-poc1 -f demos/21-tempo/values-tempo.yaml
kubectl --context kind-poc1 get --raw "/api/v1/namespaces/monitoring/services/tempo:3200/proxy/ready"
```

The first attempt failed — gotcha #67: the chart's templates read `receivers.jaeger.protocols`
unconditionally, so `jaeger: null` (to switch the unused Jaeger listeners off) breaks the render with
`nil pointer evaluating interface {}.protocols`. The default listeners stay; nobody talks to them.

```
NAME: tempo   STATUS: deployed
tempo-0   true   poc1-worker   10.10.4.124
service ports: … grpc-tempo-otlp=4317 tempo-otlp-http=4318 tempo-prom-metrics=3200 …
/ready: ready
```

## Part 2 — three wires

**The collector exports to Tempo** (`demos/10-tracing/otel-collector.yaml`, additive: the `debug`
exporter stays so `tracetree.py` keeps working):

```yaml
      otlp/tempo:
        endpoint: tempo.monitoring.svc.cluster.local:4317
        tls: {insecure: true}
    …
        traces:
          receivers: [otlp, zipkin]
          exporters: [debug, otlp/tempo]
```

**Grafana gets the Tempo datasource and the exemplar link** — in the demo 16 stack values, applied by
the same upgrade that gave the dashboards their folders (demo 16 Section C):

```yaml
  sidecar:
    datasources:
      exemplarTraceIdDestinations: {datasourceUid: tempo, traceIdLabelName: traceID}
  additionalDataSources:
    - {name: Tempo, type: tempo, uid: tempo, access: proxy, url: http://tempo.monitoring.svc.cluster.local:3200, …}
```

```
  Prometheus   uid=prometheus   exemplars=[{'datasourceUid': 'tempo', 'name': 'traceID'}]
  Tempo        uid=tempo        http://tempo.monitoring.svc.cluster.local:3200
```

**Hubble sees the headers only on the L7 proxy.** `springboot` had no policy, so its HTTP was L4 to
Hubble and there were no exemplars for it. [`20-springboot-l7-visibility.yaml`](20-springboot-l7-visibility.yaml)
is the demo 16 Part 7 pattern — an `http: [{}]` rule on the four petclinic ports plus an allow-all,
denying nothing — and it is the step the diagram calls "Cilium extracts Trace IDs from HTTP headers
without a sidecar":

```bash
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml && kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml
kubectl --context kind-poc1 apply -f demos/21-tempo/20-springboot-l7-visibility.yaml
```

## Part 3 — end to end, with the same trace id at every hop

```bash
demos/20-springboot/check.sh 10 ; sleep 35
```

**1. Hubble's exemplars for `springboot`** — the trace ids Cilium read from `traceparent` (the Java
agent's) on the proxy, attached to the latency histogram in Prometheus:

```
   exemplars: 9
    customers-service 719635fab9270092d3fe5839d051139d 0.007s
    customers-service de1849b914a260446fbf605b35d74bd1 0.015s
    vets-service      2af5b585c9ff81b8feb1651cb84cb9cb 0.823s
    visits-service    de1849b914a260446fbf605b35d74bd1 0.013s      ← one id, two services: the same request
```

**2. The same ids in Tempo** (`GET /api/traces/<id>`):

```
    trace 0e5f7f0e705c88b4acf780702f3e570e: 6 spans,  services ['api-gateway', 'visits-service']
    trace 2af5b585c9ff81b8feb1651cb84cb9cb: 13 spans, services ['api-gateway', 'vets-service']
    trace 719635fab9270092d3fe5839d051139d: 12 spans, services ['api-gateway', 'customers-service', 'visits-service']
```

**3. Tempo search by service** (the Java agent's own OTLP export, through the collector — Tempo also
holds every request that never crossed a proxy, such as the actuator probes):

```
     344931f8c63a533e18c1e507e7d52708 api-gateway GET /actuator/health/{*path} 7ms
     5556de34e4ba21db3b590cba1ecd818  api-gateway GET /actuator/prometheus     27ms
```

**4. Grafana, through its datasource, then in the browser:**

```
    GET /api/datasources/proxy/uid/tempo/api/traces/0e5f7f0e… -> 200
```

Explore → Tempo → the exemplar's id: `api-gateway: GET visits-service`, 811 ms, 6 spans —
`GET /owners/*/pets/{petId}/visits` → `VisitRepository.findByPetId` → the two `SELECT`s
([screenshot](output/screenshots/grafana-tempo-trace.png)). And the Hubble L7 dashboard for
`springboot` / `api-gateway`, a minute after the policy: P50 14 ms, P95 27 ms, P99 45 ms
([screenshot](output/screenshots/grafana-l7-springboot-exemplars.png)); its *Request Duration*
panels request exemplars (6 of the dashboard's 17 queries have `exemplar: true`), so the dots appear
on them as traffic accumulates, and clicking one opens exactly the Tempo view above.

**Opening the L7 dashboard for `springboot`: set `reporter=server`.** A URL with `reporter=client`
and a named `destination_workload` shows nothing, and the reason is measurable — the last 6 hours:

| reporter | destination_workload | requests |
|---|---|---|
| server | api-gateway | 386 |
| server | customers-service | 382 |
| server | visits-service | 377 |
| server | vets-service | 373 |
| client | `-` (empty) | 186 |

`reporter` says which side's proxy saw the request. The visibility policy above is an *ingress* rule,
so the L7 proxy is on the destination's own node and reports as `server`, with the workload name
filled in. The only `client` rows are the Cilium Gateway's Envoy calling `api-gateway`, and those
carry no `destination_workload` because the Gateway's node is not the pod's node (gotcha #58). So
`client` + any workload name matches nothing; `server` + the workload is the query. The same split
was recorded for the bank in demo 16 Part 8. A working URL:

```
https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload?from=now-6h&to=now&var-cluster=poc1&var-destination_namespace=springboot&var-destination_workload=visits-service&var-reporter=server&var-source_namespace=$__all&var-source_workload=$__all
```

## Part 6 — TraceQL metrics and Traces Drilldown ("localblocks processor not found")

*Drilldown → Traces* and any TraceQL **metrics** query (`{ … } | rate()`, `| quantile_over_time(duration, 0.9)`)
are answered by a third generator processor, **local-blocks**, which keeps recent spans in blocks it
can aggregate on demand. Without it Grafana shows *TraceQL metrics not configured … "localblocks
processor not found"*, and Tempo itself answers the query with an rpc error from the generator:

```
before: GET /api/metrics/query_range?q={ resource.service.name="api-gateway" } | rate()
   error querying generators in Querier.queryRangeRecent: failed to get response from generators: … rpc …
```

One more entry in the same overrides list and its processor block ([`values-tempo.yaml`](values-tempo.yaml)):

```yaml
    processor:
      local_blocks:
        flush_to_storage: true         # also persist the blocks it builds, so metrics queries reach back past RAM
        filter_server_spans: false     # keep client/internal spans in the metrics, not only server spans
  overrides:
    defaults:
      metrics_generator:
        processors: [service-graphs, span-metrics, local-blocks]
```

```bash
helm upgrade tempo grafana/tempo --version 1.24.4 -n monitoring --kube-context kind-poc1 -f demos/21-tempo/values-tempo.yaml
```

```
REVISION: 3   statefulset rolling update complete
after: the same query
  series: 1   [{__name__: rate}]  samples: 12  last: 0.233 spans/s
  p90 by service, last 10 min:  api-gateway  p90 ≈ 67.1 ms          ← { span:name=~"GET /api.*" } | quantile_over_time(duration, 0.9) by (resource.service.name)
```

*Drilldown → Traces*, datasource Tempo, last 30 min: span rate, error rate and duration histogram
over time, then a breakdown by `resource.service.name` — api-gateway, vets-service, visits-service,
customers-service, discovery-server, config-server — each with Include/Exclude filters, and the
*Service structure*, *Comparison* and *Traces* tabs ([screenshot](output/screenshots/grafana-traces-drilldown.png)).
This is the RED overview computed from spans alone, for every service that sends any.

**Part 6b — the first Drilldown page killed Tempo.** Captured while taking the screenshots: *Query
error … dial tcp 10.11.194.232:3200: connect: connection refused*. Not a wiring problem — Tempo was
being restarted:

```
tempo-0: restarts=1 last=OOMKilled exit=137 at=2026-09-12T12:15:55Z limit=512Mi
  last queries before the kill:  "{true && true} | rate()"                                        range 30 min
                                 "{true && true && resource.service.name != nil} | rate() by(resource.service.name)"
```

The Drilldown's opening page fires two TraceQL metrics queries over the whole time range; with the
generator holding its blocks in memory, that pushed the container past 512Mi (working set had been
250 MiB with the generator alone, Part 5). The limit is now 1Gi (`values-tempo.yaml`, revision 4);
the page reloaded with no restart and a peak working set of 159 MiB at the 15-second scrape
resolution — the spike that killed it lasted less than a scrape interval. Gotcha #68. The captures
below are from after the change: [breakdown](output/screenshots/grafana-traces-drilldown-breakdown.png),
[traces tab](output/screenshots/grafana-traces-drilldown-traces.png) (200 root spans);
[`browser-drilldown.js`](browser-drilldown.js) retakes them.

The three generator processors and what each one feeds:

| Processor | Produces | Consumed by |
|---|---|---|
| `service-graphs` | `traces_service_graph_*` in Prometheus | the Service Graph tab (Part 5) |
| `span-metrics` | `traces_spanmetrics_*` in Prometheus | the Service Graph's Rate / Duration columns; any dashboard |
| `local-blocks` | nothing in Prometheus — answers TraceQL metrics queries from Tempo's own blocks \| Traces Drilldown, Explore TraceQL `| rate()` etc. (Part 6) |

## Exercises

1. `demos/20-springboot/check.sh 10; sleep 35`, then the `query_exemplars` call from the transcript:
   *expect* trace ids per destination workload. Take one.
2. `kubectl get --raw "/api/v1/namespaces/monitoring/services/tempo:3200/proxy/api/traces/<id>"`:
   *expect* spans from at least two services — the same id.
3. Open `https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload` with
   `destination_namespace=springboot`, `destination_workload=api-gateway`, **`reporter=server`**
   (`client` shows nothing for a named workload — the table above), last 30 min. *Expect* the Request
   Duration panel with dots; click a dot → *Query with Tempo*.
4. Delete the visibility policy (`kubectl delete -f demos/21-tempo/20-springboot-l7-visibility.yaml`),
   run traffic, repeat 1: *expect* no new exemplars for `springboot` — Hubble reads headers only on the
   proxy. Re-apply it.
5. `demos/18-obi/tracetree.py` still works on the collector log: the debug exporter stayed.
6. **The Service Graph (Part 5).** With `metricsGenerator.enabled: false` in `values-tempo.yaml`
   (and the processors line removed) do `helm upgrade tempo …`, then Explore → Tempo → *Service
   Graph*: *expect* "No service graph data found" — the tab is drawn from metrics that nobody
   produces. Restore the file, upgrade again, run `demos/20-springboot/check.sh 10`, wait 90 s:
   *expect* the node graph (user → api-gateway → the three services → their databases) and
   `rate(traces_service_graph_request_total[5m])` in Prometheus with `client`/`server` labels.
   Then, without the Prometheus receiver (`enableRemoteWriteReceiver: false`, a stack upgrade):
   *expect* Tempo logging remote-write 4xx errors and the graph going stale — three switches, and
   the tab shows nothing unless all three are on.
7. **TraceQL metrics and Traces Drilldown (Part 6).** Remove `local-blocks` from the processors,
   upgrade, open *Drilldown → Traces*: *expect* "TraceQL metrics not configured … localblocks
   processor not found". Put it back: *expect* the RED overview per service and
   `{ resource.service.name="api-gateway" } | rate()` answering at Tempo's `/api/metrics/query_range`.

## Why the generator is worth its cost

The Service Graph is the only view in this lab that shows **dependencies as the applications
actually exercise them**, per direction, with rate, error rate and latency on every edge — and it
needs nothing from the applications beyond the spans they already send:

- **It finds what nobody declared.** Demo 19 rendered policy from declared intent; the graph shows
  the real call graph, so a caller that intent forgot (petclinic's Eureka heartbeats to
  `discovery-server`, every service's calls to its database) is visible before a default-deny
  policy blocks it. Hubble's Network Overview shows the same edges at L3/L4 by identity; the graph
  shows them at the application level with the operation names and the latency per hop.
- **RED per edge, not per service.** `traces_service_graph_request_*` carries `client` and `server`
  labels, so "api-gateway → customers-service is slow" is a query, not an inference from two
  per-service dashboards. The Spring Boot dashboard cannot say that; Hubble's L7 metrics can only
  for proxied ports.
- **It works for services with no metrics of their own.** The span metrics come from the
  generator, so a service that ships no Prometheus endpoint still gets rate/errors/duration by
  span name (the bank's Go services under OBI would, once petclinic is scaled down).
- **It is the entry point to the traces.** Every node and edge links to a TraceQL search; the
  Traces Drilldown (Part 6) builds its whole RED overview from the same generator.

The cost is series: 1,455 in Tempo's registry for four services after three minutes, growing with
distinct span names. That is a sizing question, not a reason to leave the tab empty.

## What to take away

- **The trace id is the join key**, and Cilium supplies it without touching the application: the
  Java agent wrote `traceparent`, the L7 proxy read it, Hubble attached it to the histogram bucket.
- **Exemplars need three switches, in three places:** `exemplars=true` + OpenMetrics on Hubble
  (demo 16), `exemplar-storage` on Prometheus (Section A), and `exemplarTraceIdDestinations` on the
  Grafana datasource (here). Missing any one, the dots are absent and nothing says why.
- **Only proxied ports produce them.** Demo 19's cell gave the bank that for free; `springboot`
  needed its own visibility policy.
- Memory after all of it: Tempo at ~150 Mi working set; the VM at ~1.8 GB available with the six
  petclinic JVMs — scale the bank back up (`demos/20-springboot/scale.sh up`) only after scaling
  petclinic down, or the other way round.

Remove it:

```bash
helm uninstall tempo -n monitoring --kube-context kind-poc1
kubectl --context kind-poc1 delete -f demos/21-tempo/20-springboot-l7-visibility.yaml
```

## Part 4 — how to look at traces in Grafana (Tempo as a datasource)

Tempo is already a datasource (uid `tempo`, Part 2; *Connections → Data sources → Tempo → Test* says
"Data source is working"). Four ways in, from the quickest to the most exact:

1. **From a metric, through an exemplar** — the pipeline this demo is about. Hubble L7 dashboard,
   `destination_namespace=springboot`, a workload, `reporter=server`, last 30 min. Hover a dot on the
   *Request Duration* panel; the tooltip shows `traceID` and a **Query with Tempo** button. Click it:
   Explore opens with that trace. Only proxied traffic has dots (Part 2), so `springboot` and the bank's
   cell have them; the Spring Boot dashboard does not (Micrometer's histograms carry no exemplars).
2. **Explore → Tempo → Search.** Pick the datasource, *Query type: Search*, service name `api-gateway`
   (or any petclinic service), a span name, min duration, status; *Run query*. A table of traces; click
   a trace id for the timeline. This is `GET /api/search` on Tempo behind the scenes.
3. **Explore → Tempo → TraceQL** for exact questions, for example every gateway fan-out slower than 100 ms:

   ```
   { resource.service.name="api-gateway" && name=~"GET /api.*" && duration > 100ms }
   ```

   or by a Kubernetes attribute the Java agent stamped (demo 20 Part 3): `{ resource.k8s.deployment.name="visits-service" }`.
4. **By trace id** — paste it as the TraceQL query. From an exemplar, from the collector's log
   (`tracetree.py`), from OBI's printer, from a Hubble flow: all the same id.

Two links that work right now (the first is a real trace from a minute ago; both open Explore on
the Tempo datasource; log in first):

- one trace: the *URL trace* line in the transcript (Part 4) — a `GET /api/gateway/owners/{ownerId}`,
  165 ms, api-gateway → customers-service and visits-service
- the TraceQL search above, last hour: the *URL traceql* line in the transcript

What you see in a trace: the service and operation per span, the timeline, and each span's
attributes — the Java agent's `http.route`, `db.statement`, `k8s.pod.name`; *Critical path*, *Errors*
and *High latency* filters on the span list. What is **not** there: logs (no Loki in this lab). The *Service Graph* tab needs Tempo's
metrics-generator and a Prometheus that accepts remote writes — Part 5.

To trace the **bank** instead of petclinic: `demos/20-springboot/scale.sh up` (after scaling petclinic
down, memory), then OBI's spans (demo 18) reach Tempo through the same collector, with
`resource.service.name="api"`, `"payments"`, `"accounts"` and `k8s.cluster.name` `poc1`/`poc2`.

## Part 5 — the Service Graph ("No service graph data found")

Grafana's Tempo datasource draws the *Service Graph* tab from **metrics**, not from traces: Tempo's
metrics-generator must derive them from the spans it receives and write them into Prometheus, and
Grafana reads them back from the Prometheus datasource named under *Service graph* in the Tempo
datasource settings (already `prometheus`, Part 2). Without the generator the tab says
"No service graph data found". Three switches, two helm upgrades:

| Switch | Where | Value |
|---|---|---|
| the generator, and the processors that make the two metric families | [`values-tempo.yaml`](values-tempo.yaml) | `metricsGenerator.enabled: true`; `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]` |
| where it writes | same | `metricsGenerator.remoteWriteUrl: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/api/v1/write` — the chart default names a Service that does not exist here |
| Prometheus accepting remote writes (a Prometheus restart) | `demos/16-monitoring/values-kube-prometheus-stack.yaml` | `prometheus.prometheusSpec.enableRemoteWriteReceiver: true` |

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml
helm upgrade tempo grafana/tempo --version 1.24.4 -n monitoring --kube-context kind-poc1 -f demos/21-tempo/values-tempo.yaml
```

```
before: enableRemoteWriteReceiver=[]     after: enableRemoteWriteReceiver=[true]
tempo.yaml:  overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]
             metrics_generator.storage.remote_write: [{url: http://monitoring-kube-prometheus-prometheus…:9090/api/v1/write}]
tempo log:   msg=starting module=metrics-generator
             (one transient "error tailing WAL" while its remote-write WAL is created — gone after the first flush)
tempo /metrics: spans_received_total 984 · processor_service_graphs_edges 491 · registry_active_series 1455     ← 3 min of traffic
```

**In Prometheus, remote-written — the edges** (`rate(traces_service_graph_request_total[5m])`):

```
   0.2126  client=user               server=api-gateway          ← "user": a root span with no caller (the Gateway's requests)
   0.0357  client=api-gateway        server=visits-service
   0.0357  client=api-gateway        server=customers-service
   0.0179  client=api-gateway        server=discovery-server     ← Eureka heartbeats
   0.0952  client=customers-service  server=d18b97ce-8358-…      ← the database: HSQLDB's in-memory db name is a UUID,
   0.0608  client=vets-service       server=370e59a6-4fed-…         so the Java agent's db.name, and the graph's node, is one
```

and `traces_spanmetrics_calls_total` by service and span name (`GET /api/gateway/owners/{ownerId}`,
`OwnerRepository.findById`, `SELECT …`, …) — the RED numbers the graph's *Rate* / *Duration (p90)*
columns and node badges come from.

**The datasource link, and where it is written.** Grafana's service-graph docs show it as a
provisioning file:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: <prometheus-url>
  - name: Tempo
    type: tempo
    uid: tempo
    url: <tempo-url>
    jsonData:
      serviceMap:
        datasourceUid: 'prometheus'
```

Nobody writes that file here: kube-prometheus-stack renders it from values into the ConfigMap
`monitoring-kube-prometheus-grafana-datasource` (label `grafana_datasource=1`), which the Grafana
datasource sidecar provisions — the same mechanism as the dashboards. The mapping from the docs'
file to the stack values (`demos/16-monitoring/values-kube-prometheus-stack.yaml`):

| Docs' provisioning file | Stack value | Live (from `/api/datasources`) |
|---|---|---|
| Prometheus datasource, `uid: prometheus` | `grafana.sidecar.datasources` (the chart creates it; `uid: prometheus` is its default) | `Prometheus uid=prometheus url=http://monitoring-kube-prometheus-prometheus.monitoring:9090/` |
| plus the exemplar link (Part 2) | `grafana.sidecar.datasources.exemplarTraceIdDestinations: {datasourceUid: tempo, traceIdLabelName: traceID}` | `exemplarTraceIdDestinations: [{datasourceUid: tempo, name: traceID}]` |
| Tempo datasource, `uid: tempo`, `serviceMap.datasourceUid: prometheus` | `grafana.additionalDataSources: [{name: Tempo, type: tempo, uid: tempo, url: http://tempo.monitoring.svc.cluster.local:3200, jsonData: {serviceMap: {datasourceUid: prometheus}, tracesToMetrics: {datasourceUid: prometheus}}}]` | `Tempo uid=tempo jsonData={serviceMap: {datasourceUid: prometheus}, tracesToMetrics: {…}}` |

`httpMethod` is left at the chart's `POST` for Prometheus (the docs' `GET` is optional; POST allows
long queries). To read the rendered file:

```bash
kubectl --context kind-poc1 -n monitoring get cm monitoring-kube-prometheus-grafana-datasource -o jsonpath='{.data.datasource\.yaml}'
```

**In Grafana:** Explore → Tempo → query type *Service Graph*, last 30 min: the four petclinic
services as nodes with the database nodes hanging off them, request rate and p90 on the edges, and
a table with Rate / Error rate / Duration per node ([screenshot](output/screenshots/grafana-service-graph.png);
the same view over the last hour, captured at 2× with [`browser-service-graph.js`](browser-service-graph.js):
[grafana-service-graph-1h.png](output/screenshots/grafana-service-graph-1h.png)).
Clicking a node runs a TraceQL search for that service; the Spring Boot dashboard's *Rate* and
this graph's *Rate* are the same requests counted by two independent instruments (Micrometer in the
JVM; the generator from spans).

Cost: Tempo's registry holds 1,455 series for four services after three minutes of light traffic;
`span-metrics` in particular grows with every distinct span name (`db.statement` names included).
On a busy cluster that is the processor to turn off first, or to filter.

## Evidence

Captured 2026-09-12 with `scripts/evidence/capture.js` and `scripts/evidence/collect.sh` (both re-runnable; the pod and Cilium output is the recorded file [`output/evidence.txt`](output/evidence.txt)). Every image is what the browser saw, with traffic running.

**grafana service graph** — the service graph from Tempo’s metrics-generator, full page: the table of routes with rate and p90 above, the node graph below — user → web → api → payments → accounts across the mesh, each node with its ms/request and req/s

![grafana-service-graph](output/screenshots/grafana-service-graph.png)

**grafana traces drilldown** — Traces Drilldown by service: rate, errors, duration per service from the stored spans

![grafana-traces-drilldown](output/screenshots/grafana-traces-drilldown.png)

**Running pods** (from `output/evidence.txt`):

```console
$ kubectl --context kind-poc1 -n monitoring get pods -o wide
NAME                                                     READY   STATUS    RESTARTS        AGE     IP            NODE                  NOMINATED NODE 
alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2     Running   0               19h     10.10.3.207   poc1-worker2          <none>         
loki-0                                                   2/2     Running   0               7h49m   10.10.3.140   poc1-worker2          <none>         
monitoring-grafana-85f995b8c8-gqnc8                      3/3     Running   0               11h     10.10.4.99    poc1-worker           <none>         
monitoring-kube-prometheus-operator-57b74d8f5b-zw957     1/1     Running   9 (102s ago)    19h     10.10.3.227   poc1-worker2          <none>         
monitoring-kube-state-metrics-7f584dc46d-dpxkb           1/1     Running   11 (113s ago)   19h     10.10.4.165   poc1-worker           <none>         
monitoring-prometheus-node-exporter-d9h5h                1/1     Running   3 (2m1s ago)    19h     172.18.0.7    poc1-control-plane2   <none>         
monitoring-prometheus-node-exporter-fzxrc                1/1     Running   2 (100s ago)    19h     172.18.0.3    poc1-control-plane3   <none>         
monitoring-prometheus-node-exporter-jwqp7                1/1     Running   4 (7h31m ago)   19h     172.18.0.5    poc1-worker           <none>         
monitoring-prometheus-node-exporter-n6jl7                1/1     Running   3 (7h31m ago)   19h     172.18.0.6    poc1-control-plane    <none>         
monitoring-prometheus-node-exporter-nqvbt                1/1     Running   1 (8h ago)      19h     172.18.0.4    poc1-worker2          <none>         
prometheus-monitoring-kube-prometheus-prometheus-0       2/2     Running   1 (68s ago)     177m    10.10.3.98    poc1-worker2          <none>         
tempo-0                                                  1/1     Running   6 (78s ago)     8h      10.10.3.228   poc1-worker2          <none>         
```

The Cilium/kubectl commands that prove this demo's claim, with their output, follow the pod listings in [`output/evidence.txt`](output/evidence.txt).
