# Demo 20 — Spring Boot microservices (spring-petclinic-microservices) in namespace `springboot`

## Summary context

The bank (demo 15) is Go. Most of what people run is Java, and the observability story for Java is
different: OBI traces Go with uprobes on the runtime and everything else through its generic
kernel-side tracer, and Java also has the standard zero-code path of its own, the OpenTelemetry Java
agent. This demo deploys the canonical Spring Boot sample — [spring-petclinic-microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)
(Spring Boot 3.4, Java 17, six JVMs: config-server, discovery-server, api-gateway, customers, vets,
visits) — in a namespace of its own, on the Gateway as `https://petclinic.poc.local`, sends its own
spans to the demo 10 collector, and then measures both instrumentation paths.

Everything below is recorded in [`output/transcript.txt`](output/transcript.txt).

> **Step by step, as exercises, every manifest and every command with its reason: [`GUIDE.md`](GUIDE.md).**

## Part 0 — make room (scale the bank and routes down, and back up)

Six JVMs need ~2.5 GB. The Docker Desktop VM has 16 GB for three kind clusters and everything the
earlier demos left running, and was at ~2.8 GB available with load 20 when this demo started. So
the bank's and demo 09's Deployments go to zero for the duration; the StatefulSets (Postgres primary
and standby, Redis) keep running — they hold the demo 15 ledger and the replication slot.
[`scale.sh`](scale.sh) does both directions:

```bash
demos/20-springboot/scale.sh down      # bank (poc1 + poc2) and routes Deployments → 0
demos/20-springboot/scale.sh up        # the demo 15 / demo 09 counts again
```

Which is, spelled out:

```bash
# down
kubectl --context kind-poc1 -n bank   scale deploy --all --replicas=0
kubectl --context kind-poc2 -n bank   scale deploy --all --replicas=0
kubectl --context kind-poc1 -n routes scale deploy --all --replicas=0
# up
kubectl --context kind-poc1 -n bank scale deploy api web --replicas=2 && kubectl --context kind-poc1 -n bank scale deploy payments --replicas=1
kubectl --context kind-poc2 -n bank scale deploy accounts --replicas=2 && kubectl --context kind-poc2 -n bank scale deploy payments --replicas=1
kubectl --context kind-poc1 -n routes scale deploy echo grpc web --replicas=2
```

Recorded on the first run: poc1/bank `api payments web` → 0, poc1/routes `echo grpc web` → 0,
poc2/bank `accounts payments` → 0; left running `postgres-standby-0`, `redis-0` (poc1) and
`postgres-0` (poc2). Scale up before running `demos/15-bank/exercise.sh` or `scripts/check-routes.sh`
again — with the Deployments at zero, both report failures that are not failures.

## Part 1 — six JVMs, and the three things the compose file did not have to know

**What was deployed** ([`10-petclinic.yaml`](10-petclinic.yaml), every deviation from the upstream
docker-compose commented in the file): images `springcommunity/spring-petclinic-*:3.4.1` (2025-08-31,
Java 17, Spring Boot 3.4) pinned by digest; profile `docker`, so the services import config from
`http://config-server:8888` and register with Eureka at `http://discovery-server:8761` — Kubernetes
Services with exactly those names make the compose names resolve; the config server pulls its git
repository from GitHub (egress works since demo 19 Part 0; `springboot` has no policy, it is not in a
cell); capped heaps (`-XX:MaxRAMPercentage=65`, SerialGC, C1 only) and tight limits; init containers
for the startup order; and the app's own Micrometer spans to the demo 10 collector, which gained a
Zipkin receiver, through an `ExternalName` Service called `tracing-server` (the compose name).

```bash
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml && kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector
kubectl --context kind-poc1 apply -f demos/18-obi/20-collector-service.yaml     # + port 9411 (and the same object in poc2)
kubectl --context kind-poc1 apply -f demos/20-springboot/10-petclinic.yaml
kubectl --context kind-poc1 apply -f demos/20-springboot/20-gateway.yaml        # https://petclinic.poc.local → api-gateway:8080
```

**Three fixes on the way up, all in the transcript:**

1. **The config server's probes.** `/actuator/health/liveness` and `/readiness` on the config server
   are captured by its config-serving controller (`/{app}/{profile}/{label}` → jgit
   `Ref readiness cannot be resolved`, then `Cannot check out from unborn branch` → 404/500), and
   kubelet restarted it 8 times. `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` did not change
   that (measured). Its probes use plain `/actuator/health`, the path the startup probe had already
   passed on. The other five load the shared config, which enables the probe groups; they keep them.
2. **The Zipkin endpoint.** The config repository's `docker` profile sets
   `management.tracing.export.zipkin.endpoint`, a pre-3.4 key; Spring Boot 3.4 reads
   `management.zipkin.tracing.endpoint` and exported to `localhost:9411` (`Dropped 44 spans …
   Connect to http://localhost:9411`). One env var on all six, rolled one at a time.
3. **Eureka after a rollout (gotcha #65).** With every pod Ready, the API through the Gateway still
   answered 405 / 500 / 15-s timeouts for a minute or two, while the same paths inside the api-gateway
   pod returned 200. Hubble named it: `api-gateway → 10.10.3.50:8081 STALE_OR_UNROUTABLE_IP` ×14 —
   the *previous* customers-service pod IP. Spring Cloud Gateway routes `lb://customers-service`
   through Eureka's client-side registry (30-s cache), not through the Kubernetes Service; after a pod
   is replaced it keeps handing out the dead IP until the cache expires. The bank (Kubernetes Services,
   Cilium socket-LB) has no such window — demo 15 measured zero failed requests through scale-to-0.

**The result, with every JVM Ready:**

```
  API-GATEWAY          1 instance(s)  UP        ← Eureka, the compose names resolved through Kubernetes Services
  CUSTOMERS-SERVICE    1 instance(s)  UP
  VETS-SERVICE         1 instance(s)  UP
  VISITS-SERVICE       1 instance(s)  UP

  GET /api/customer/owners                   200 in 0.100070s
  GET /api/customer/owners/1                 George Franklin pets: ['Leo']
  GET /api/vet/vets                          6 vets
  GET /api/visit/owners/1/pets/1/visits      2 visits
  GET /api/gateway/owners/1 (gateway fan-out) 200 in 0.069723s
  POST /api/visit/owners/1/pets/1/visits     201
  6 × GET /api/gateway/owners/1:             200 200 200 200 200 200 (56–100 ms)

  spans by service.name (last 2 min, the collector's zipkin receiver):
    api-gateway 26 · customers-service 18 · vets-service 13 · visits-service 20
```

Memory: the VM went from ~2.8 GB available to ~1.8 GB with six JVMs running (Part 0's scale-down
included); `config-server` at 148 MiB working set, the services under their limits.

**Hosts block** (you run the `sudo` line; same pattern as demos 09, 15, 16):

```bash
demos/20-springboot/hosts-entries.sh
sudo sh -c 'demos/20-springboot/hosts-entries.sh >> /etc/hosts'
dscacheutil -flushcache; sudo killall -HUP mDNSResponder
open https://petclinic.poc.local
```

## Part 2 — OBI on the Java services: found, classified, and stopped by the same kernel gap

`{k8s_namespace: springboot}` was added to OBI's discovery (`demos/18-obi/10-obi.yaml`) and OBI
redeployed on poc1. OBI does two things for Java: it injects a tiny Java agent of its own into the
JVM (for TLS and thread-pool context) and traces the network at the kernel with its generic tracer.
Both were observed, neither produced a span:

```
  attach  /opt/java/openjdk/bin/java pid=41405 (java)                            ← ×4 on poc1-worker2, ×1 on poc1-worker
  msg="injecting OpenTelemetry eBPF instrumentation for Java process" component=javaagent.Injector
  level=ERROR msg="couldn't attach OpenTelemetry eBPF Java Agent" … error="… use of closed network connection"
  level=WARN  msg="java attach timed out" timeout=10s
  level=WARN  msg="unable to attach java agent to process, Java TLS telemetry will not work"
  STOP    "instrumenting function \"security_socket_accept\": setting kprobe: … token __x64_security_socket_accept: not found"

  OBI printer lines for springboot services (last 3 min):  count: 0
```

The stop is the demo 18 Part 3 error to the letter — `CONFIG_SECURITY` is not set in this Docker
Desktop kernel, so the LSM socket hooks OBI's non-Go tracer attaches to do not exist (gotcha #60).
Go was traced (uprobes); Java, Postgres and Redis are not. The app's own Micrometer spans kept
flowing throughout, so Java on this rig has tracing — just not from the kernel. Part 3 is the other
zero-code path, which does not depend on the kernel at all.

## Part 3 — the OpenTelemetry Java agent: zero code, no kernel dependency

[`30-javaagent-patch.yaml`](30-javaagent-patch.yaml), applied by [`javaagent.sh on`](javaagent.sh) to
one Deployment at a time (a patch is a rolling restart; six cold JVMs at once would double the memory
the VM has left): an init container fetches `opentelemetry-javaagent.jar` **v2.31.1** (2026-08-23,
pinned) into an `emptyDir`, `JAVA_TOOL_OPTIONS` gains `-javaagent:…`, the OTLP endpoint is the demo 10
collector (`http://otel-collector.otel.svc.cluster.local:4318`, http/protobuf), `OTEL_SERVICE_NAME`
and `k8s.*` resource attributes are set per Deployment, and the app's own Zipkin export is switched
off (`MANAGEMENT_ZIPKIN_TRACING_EXPORT_ENABLED=false`) so nothing arrives twice. No image was rebuilt.

```
  config-server      patched; deployment "config-server" successfully rolled out
  discovery-server   patched; …                                                  ← ×6, one after the other
  Picked up JAVA_TOOL_OPTIONS: -javaagent:/otel/opentelemetry-javaagent.jar -XX:MaxRAMPercentage=65 …
  [otel.javaagent … ] INFO io.opentelemetry.javaagent.tooling.VersionLogger - opentelemetry-javaagent - version: 2.31.1
  6 × GET /api/gateway/owners/1: 200 … (56–100 ms)                             ← the API, unchanged
  VM memory: available 1821 MB

  collector, last 2 min, springboot spans by telemetry SDK:
    api-gateway        opentelemetry/java/1.65.0    50 spans      ← the agent
    config-server      opentelemetry/java/1.65.0   114 spans      ← even the infrastructure JVMs
    customers-service  opentelemetry/java/1.65.0    51 spans
    discovery-server   opentelemetry/java/1.65.0    93 spans
    vets-service       opentelemetry/java/1.65.0    49 spans
    visits-service     opentelemetry/java/1.65.0    85 spans
```

**One request through the Gateway, as a tree** (`demos/18-obi/tracetree.py`) — the gateway's fan-out
to two services, each down to the repository call, the Hibernate session and the SQL statement:

```
trace 7dff58a4f2ac1df9834e7a33197ab8f5: 12 spans, clusters ['poc1']
GET /api/gateway/owners/{ownerId}  [Server]  poc1/api-gateway  70.2 ms  petclinic.poc.local
  GET  [Client]  poc1/api-gateway  20.9 ms
    GET /owners/{ownerId}  [Server]  poc1/customers-service  16.4 ms
      OwnerRepository.findById  [Internal]  10.5 ms
        Session.find …customers.model.Owner  [Internal]  5.2 ms
          SELECT …  [Client]  0.2 ms                                   ← HSQLDB, in-process
        Transaction.commit  [Internal]  0.3 ms
  GET  [Client]  poc1/api-gateway  26.1 ms
    GET /pets/visits  [Server]  poc1/visits-service  20.7 ms
      VisitRepository.findByPetIdIn  [Internal]  15.4 ms
        SELECT …visits.model.Visit  [Internal]  11.1 ms
          SELECT ….visits  [Client]  0.6 ms
```

Compare with what OBI gave the Go bank in demo 18: HTTP server/client spans, Redis and SQL client
spans, and nothing inside the process. The Java agent sees the framework — repositories, ORM, commits —
because it runs *in* the JVM. That is the trade: it needs a JVM flag and a jar in the pod; OBI needs
nothing in the pod and a kernel with the LSM hooks.

## What to take away

- **A Spring Boot system runs on this rig under Cilium with no special casing**: Eureka, the config
  server, the gateway, three services, all through the same Gateway API and the same collector.
- **The three fixes were Spring's, not Cilium's**, and Cilium's observability found the third one:
  the Eureka stale-IP window (gotcha #65) was a Hubble drop reason, not a guess.
- **OBI on Java is blocked by the same kernel gap as Postgres and Redis** (gotcha #60), measured
  twice: the agent injection timed out and the generic tracer stopped on `security_socket_accept`.
- **The OpenTelemetry Java agent is the zero-code path for Java that works everywhere**, and it goes
  deeper than any kernel tracer can — at the cost of living in the pod.
- **Memory is the constraint of this lab, and `scale.sh` is how it is managed**: six JVMs cost the
  bank and demo 09 their replicas for the duration.

Back to normal:

```bash
demos/20-springboot/javaagent.sh off                                   # the plain manifest again
kubectl --context kind-poc1 delete -f demos/20-springboot/20-gateway.yaml -f demos/20-springboot/10-petclinic.yaml   # remove the lab
demos/20-springboot/scale.sh up                                        # the bank and demo 09 back
```

## Part 4 — petclinic on Grafana

Two things put it there, both in [`40-monitoring.yaml`](40-monitoring.yaml), the same mechanisms
demo 16 used for Cilium:

- a **PodMonitor** for the four application JVMs' `/actuator/prometheus` (Micrometer). The
  discovery server answers 404 there and the config server exposes no JVM metrics — neither loads the
  shared config — so they are not selected. Relabelings give the series what the standard dashboard's
  variables query: `application` = the pod's `app` label, `instance` = the pod name, plus `node` and
  `cluster`. (Two services also send their own `application="petclinic"` tag; with `honor_labels`
  off it becomes `exported_application` and the relabeled one wins.)
- a **ConfigMap** carrying grafana.com dashboard 19004, *Spring Boot 3.x Statistics*, with its
  datasource input resolved to the demo 16 Prometheus, labelled `grafana_dashboard=1` so Grafana's
  sidecar loads it from the `springboot` namespace exactly as it loads Cilium's from `kube-system`.
  How that ConfigMap was made (download, placeholder resolution, uid, label) is documented once,
  in demo 16 Part 1b, and is now `demos/16-monitoring/dashboard-configmap.sh`, which regenerates it.

```bash
kubectl --context kind-poc1 apply -f demos/20-springboot/40-monitoring.yaml
```

```
  vets-service       http://10.10.3.1:8083/actuator/prometheus    up
  visits-service     http://10.10.3.182:8082/actuator/prometheus  up
  api-gateway        http://10.10.3.5:8080/actuator/prometheus    up
  customers-service  http://10.10.3.212:8081/actuator/prometheus  up
  jvm_info: application=api-gateway|customers-service|vets-service|visits-service  version=17.0.16+8
  heap in use (MiB): vets-service 104 · api-gateway 89 · visits-service 83 · customers-service 83
  Spring Boot 3.x Statistics (petclinic)   https://grafana.poc.local/d/springboot-19004/spring-boot-3-x-statistics-petclinic
```

**Where to look, in order:**

| What you want | Where | Notes |
|---|---|---|
| JVM heap, GC, threads, HTTP request rate and latency per service | Grafana → *Spring Boot 3.x Statistics (petclinic)*, pick `application` | Micrometer, scraped every 15 s |
| flows and drops of the namespace, identity-aware | Grafana → *Hubble / Network Overview (Namespace)*, `source_namespace=springboot` | L4 only: `springboot` has no L7 policy (demo 19's cell was the bank) |
| per-route HTTP metrics from the kernel side | *Hubble L7 HTTP Metrics by Workload* | empty for `springboot` until it gets an `http: [{}]` policy like the bank's |
| a request as a tree of spans | the collector's log — `kubectl -n otel logs ds/otel-collector \| demos/18-obi/tracetree.py "GET /api/gateway"` | Grafana shows no traces: there is no trace store (Tempo) in this lab, only the debug exporter |

The last row is the honest gap: spans are collected, not stored. A Grafana Tempo instance behind the
collector is the missing piece for a traces view, and on this VM it is another JVM-sized allocation
— a follow-up, not a default.
