# Demo 21 — Grafana Tempo: from a Hubble exemplar to the full trace, with Cilium doing the header work

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
