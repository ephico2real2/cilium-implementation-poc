# Demo 20 — the junior guide: every manifest, every command, and why

The README explains the results; this file is the walk, as exercises. Each step is **the command**,
**why** (one line), and **what to expect**. Manifests are shown straight from the files so this page
cannot drift from what is applied. Run from the repo root. Prerequisites: poc1 built per
`docs/SETUP.md` (Cilium, the demo 09 Gateway, the demo 10 collector, the demo 16 stack, demo 18's
OBI), and external DNS working from pods (demo 19 Part 0, gotcha #63 — the config server clones
its configuration from GitHub).

---

## Exercise 0 — make room

```bash
demos/20-springboot/scale.sh down
```
*Why:* six JVMs need ~2.5 GB; the VM had ~2.8 GB available at load 20. The bank's and demo 09's
Deployments go to zero; the StatefulSets (Postgres, Redis) keep the demo 15 ledger.
*Expect:* `poc1/bank api payments web -> 0 … poc2/bank accounts payments -> 0 … routes echo grpc web -> 0`,
then `VM available: ~2800 MB`. Remember `scale.sh up` at the end (Exercise 10).

## Exercise 1 — teach the collector Zipkin (the app's own spans)

```bash
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml
kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector
kubectl --context kind-poc1 apply -f demos/18-obi/20-collector-service.yaml
kubectl --context kind-poc2 apply -f demos/18-obi/20-collector-service.yaml
```
*Why:* Spring Boot's `docker` profile exports Micrometer spans in **Zipkin** format to
`tracing-server:9411`. The demo 10 collector gained a `zipkin` receiver on its `traces` pipeline,
and the global Service (demo 18) a `9411` port — the same object in both clusters, the ClusterMesh rule.
*Expect:* `configmap/otel-collector configured`, `service/otel-collector configured` ×2.

The receiver block that was added (from `demos/10-tracing/otel-collector.yaml`):

```yaml
      # Added in demo 20: the Spring Boot services export their own Micrometer spans in Zipkin format.
      zipkin: {endpoint: 0.0.0.0:9411}
    …
        traces:
          receivers: [otlp, zipkin]
```

## Exercise 2 — deploy petclinic

```bash
kubectl --context kind-poc1 apply -f demos/20-springboot/10-petclinic.yaml
```
*Why:* the upstream project ships docker-compose only; this file is its translation, with the
reasons for every deviation in the header. Read the header first:

```yaml
# Demo 20 — Spring Boot microservices: the canonical spring-petclinic-microservices (Spring Boot 3.4 / Java 17,
# images springcommunity/spring-petclinic-*:3.4.1 of 2025-08-31, pinned by digest), in namespace `springboot`.
# The upstream project ships docker-compose only; these manifests translate it. Deviations, with reasons:
#   * profile `docker`: the services then import config from http://config-server:8888 and register with Eureka at
#     http://discovery-server:8761 — Kubernetes Services with exactly those names make the compose names resolve.
#   * config-server pulls its git config from GitHub (spring-petclinic-microservices-config): pod egress to the
#     world works since demo 19 Part 0 (CoreDNS forward) and `springboot` has no policy — it is NOT in the cell (yet).
#   * memory: six JVMs on ~3 GB of VM headroom — capped heaps (JAVA_TOOL_OPTIONS) and tight limits; the compose has none.
#   * startup order (compose: depends_on/healthcheck): init containers wait for config-server, then discovery-server.
#   * tracing: the docker profile exports Micrometer spans to http://tracing-server:9411 (Zipkin). `tracing-server` is an
#     ExternalName to the demo 10 collector, which gained a zipkin receiver — the app's OWN spans, before any OBI (Part 2).
#   * admin-server, genai-service, zipkin/prometheus/grafana of the compose: not deployed (memory; demo 16 has the stack).
#   kubectl --context kind-poc1 apply -f demos/20-springboot/10-petclinic.yaml
apiVersion: v1
kind: Namespace
metadata: {name: springboot}
---
apiVersion: v1
kind: Service
metadata: {name: tracing-server, namespace: springboot}
spec:
  type: ExternalName                                   # the compose name for Zipkin → the demo 10 collector (zipkin receiver :9411)
  externalName: otel-collector.otel.svc.cluster.local
  ports: [{port: 9411, targetPort: 9411}]
```

The config server — the one Deployment whose probes differ, and why (the block as applied):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: config-server, namespace: springboot, labels: {app: config-server}}
spec:
  replicas: 1
  selector: {matchLabels: {app: config-server}}
  template:
    metadata: {labels: {app: config-server}}
    spec:
      containers:
        - name: config-server
          image: springcommunity/spring-petclinic-config-server@sha256:db14626a92afda51963a29804fe24329b7711467ffdc7dc2157fe800abc3f756   # 3.4.1
          ports: [{name: http, containerPort: 8888}]
          env:
            - {name: SPRING_PROFILES_ACTIVE, value: docker}
            # The config repo's docker profile sets management.tracing.export.zipkin.endpoint (a pre-3.4 key); Spring Boot
            # 3.4 reads management.zipkin.tracing.endpoint and so exported to localhost:9411 ("Dropped 44 spans …
            # Connect to http://localhost:9411", measured). The 3.4 key, pointed at the collector's ExternalName:
            - {name: MANAGEMENT_ZIPKIN_TRACING_ENDPOINT, value: http://tracing-server:9411/api/v2/spans}
            - {name: JAVA_TOOL_OPTIONS, value: "-XX:MaxRAMPercentage=65 -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k"}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 320Mi}}
          startupProbe: {httpGet: {path: /actuator/health, port: 8888}, periodSeconds: 5, failureThreshold: 60}   # up to 5 min for a cold JVM on a loaded VM
          # config-server: /actuator/health ONLY. Its probe groups /actuator/health/{liveness,readiness} are captured by the
          # config-serving controller (/{app}/{profile}/{label}: "Ref readiness cannot be resolved", then "Cannot check out
          # from unborn branch" → 404/500) and kubelet restarted it 8 times. MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true
          # did not change that (measured). The other five load the shared config, which enables the groups: they keep them.
          readinessProbe: {httpGet: {path: /actuator/health, port: 8888}, periodSeconds: 5}
          livenessProbe: {httpGet: {path: /actuator/health, port: 8888}, periodSeconds: 10, failureThreshold: 6}
```

One application service — note the init containers (the compose file's `depends_on`) and the
Zipkin key (from the file, `customers-service`; vets and visits differ only in name and port):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: customers-service, namespace: springboot, labels: {app: customers-service}}
spec:
  replicas: 1
  selector: {matchLabels: {app: customers-service}}
  template:
    metadata: {labels: {app: customers-service}}
    spec:
      initContainers:
        - name: wait-config-server
          image: alpine:3.20
          command: [sh, -c, 'until wget -qO- http://config-server:8888/actuator/health >/dev/null 2>&1; do echo waiting for config-server; sleep 3; done']
        - name: wait-discovery-server
          image: alpine:3.20
          command: [sh, -c, 'until wget -qO- http://discovery-server:8761/actuator/health >/dev/null 2>&1; do echo waiting for discovery-server; sleep 3; done']
      containers:
        - name: customers-service
          image: springcommunity/spring-petclinic-customers-service@sha256:ab1181fed9b1c23a74a442c1c1625f1ab34b4e0e928192cb5db77eef3f75b14a   # 3.4.1
          ports: [{name: http, containerPort: 8081}]
          env:
            - {name: SPRING_PROFILES_ACTIVE, value: docker}
            # The config repo's docker profile sets management.tracing.export.zipkin.endpoint (a pre-3.4 key); Spring Boot
            # 3.4 reads management.zipkin.tracing.endpoint and so exported to localhost:9411 ("Dropped 44 spans …
            # Connect to http://localhost:9411", measured). The 3.4 key, pointed at the collector's ExternalName:
            - {name: MANAGEMENT_ZIPKIN_TRACING_ENDPOINT, value: http://tracing-server:9411/api/v2/spans}
            - {name: JAVA_TOOL_OPTIONS, value: "-XX:MaxRAMPercentage=65 -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k"}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 448Mi}}
          startupProbe: {httpGet: {path: /actuator/health, port: 8081}, periodSeconds: 5, failureThreshold: 60}   # up to 5 min for a cold JVM on a loaded VM
          readinessProbe: {httpGet: {path: /actuator/health/readiness, port: 8081}, periodSeconds: 5}
          livenessProbe: {httpGet: {path: /actuator/health/liveness, port: 8081}, periodSeconds: 10, failureThreshold: 6}
```

*Expect:* `namespace/springboot created`, `service/tracing-server created`, then six Services and six
Deployments created.

## Exercise 3 — watch it come up (5–10 minutes on this VM), and see the probe trap for yourself

```bash
kubectl --context kind-poc1 -n springboot get pods -w
```
*Why:* the order is enforced by init containers: config-server first (its startup probe passes on
`/actuator/health`), then discovery-server, then the four that wait for both.
*Expect:* `Init:0/1` / `Init:0/2` on five pods while config-server starts; then `Running` one after
another. Startup probes allow 5 minutes per cold JVM.

The trap, reproduced on purpose once config-server is Ready:

```bash
kubectl --context kind-poc1 -n springboot exec deploy/config-server -c config-server -- sh -c 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8888/actuator/health; curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8888/actuator/health/readiness'
```
*Why:* the second URL is answered by the config-serving controller (`/{app}/{profile}/{label}` →
git label "readiness"), not by the actuator — which is why the manifest probes `/actuator/health` only.
*Expect:* `200` then `404` (or `500`), and in `kubectl logs deploy/config-server` a jgit stack trace
ending in `Ref readiness cannot be resolved` / `Cannot check out from unborn branch`.

```bash
for d in config-server discovery-server customers-service vets-service visits-service api-gateway; do kubectl --context kind-poc1 -n springboot rollout status deploy/$d --timeout=10m; done
```
*Expect:* six `successfully rolled out`.

## Exercise 4 — the Gateway route and the hosts block

```yaml
# Demo 20 — the petclinic UI/API on the demo 09 Gateway as https://petclinic.poc.local (wildcard cert).
#   kubectl --context kind-poc1 apply -f demos/20-springboot/20-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: petclinic, namespace: routes}
spec:
  parentRefs: [{name: routes-gw}]
  hostnames: ["petclinic.poc.local"]
  rules:
    - backendRefs: [{name: api-gateway, namespace: springboot, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata: {name: allow-routes-to-petclinic, namespace: springboot}
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: routes}]
  to: [{group: "", kind: Service, name: api-gateway}]
```

```bash
kubectl --context kind-poc1 apply -f demos/20-springboot/20-gateway.yaml
kubectl --context kind-poc1 -n routes get httproute petclinic
demos/20-springboot/hosts-entries.sh                                  # review
sudo sh -c 'demos/20-springboot/hosts-entries.sh >> /etc/hosts'      # you run this
dscacheutil -flushcache; sudo killall -HUP mDNSResponder
open https://petclinic.poc.local
```
*Why:* one HTTPRoute on the demo 09 Gateway (the wildcard certificate covers the name) and the
ReferenceGrant that lets a route in `routes` reach a Service in `springboot` (gotcha #32).
*Expect:* `ACCEPTED True  RESOLVED True`, and the petclinic UI in the browser.

## Exercise 5 — exercise the API, read Eureka, and reproduce the stale-IP window (gotcha #65)

```bash
demos/20-springboot/check.sh 5
```
*Why:* owners, a fan-out, vets, visits, and a POST — every route the gateway defines, through the Cilium Gateway.
*Expect:* `200`, `George Franklin pets: ['Leo']`, `6 vets`, `… visits`, `200`, `201`, five `200`s at 50–100 ms.

```bash
kubectl --context kind-poc1 -n springboot exec deploy/discovery-server -c discovery-server -- curl -s -H accept:application/json http://localhost:8761/eureka/apps | python3 -c 'import json,sys; [print(a["name"], len(a["instance"]), a["instance"][0]["status"]) for a in json.load(sys.stdin)["applications"]["application"]]'
```
*Why:* the gateway routes `lb://customers-service` through Eureka, not through the Kubernetes Service. This is who Eureka knows.
*Expect:* `API-GATEWAY 1 UP`, `CUSTOMERS-SERVICE 1 UP`, `VETS-SERVICE 1 UP`, `VISITS-SERVICE 1 UP`.

The window, reproduced (optional, ~3 minutes):

```bash
kubectl --context kind-poc1 -n springboot rollout restart deploy/customers-service
kubectl --context kind-poc1 -n springboot rollout status deploy/customers-service --timeout=10m
demos/20-springboot/check.sh 3          # immediately after "successfully rolled out"
hubble observe -P --kube-context kind-poc1 --namespace springboot --verdict DROPPED --since 3m
sleep 90; demos/20-springboot/check.sh 3
```
*Why:* the pod is replaced; Eureka's client-side cache (30 s) in the gateway still holds the old IP.
*Expect:* first check: `405` / `500` / `000` on the customer paths; Hubble: `api-gateway → <old pod IP>:8081 … STALE_OR_UNROUTABLE_IP`;
second check: all `200`. Nothing to fix in Cilium — it reported the cause. Kubernetes Services (the bank) have no such window.

## Exercise 6 — the app's own spans, as a tree

```bash
demos/20-springboot/check.sh 3; sleep 20
kubectl --context kind-poc1 -n otel logs ds/otel-collector --since=3m | grep "service.name:" | sort | uniq -c
kubectl --context kind-poc1 -n otel logs ds/otel-collector --since=3m | demos/18-obi/tracetree.py "GET /api/gateway"
```
*Why:* Micrometer (Spring Boot's own tracing) → Zipkin format → the collector; `tracetree.py` (demo 18) draws any trace the debug exporter printed.
*Expect:* `api-gateway`, `customers-service`, `vets-service`, `visits-service` spans, and a tree rooted at `GET /api/gateway/owners/{ownerId}`.

## Exercise 7 — OBI on Java: run it, read the log, know why it is empty here

```bash
grep -n springboot demos/18-obi/10-obi.yaml       # the discovery entry demo 20 added
demos/18-obi/deploy.sh poc1
sleep 60; demos/20-springboot/check.sh 3; sleep 20
for p in $(kubectl --context kind-poc1 -n obi get pods -o name | cut -d/ -f2); do kubectl --context kind-poc1 -n obi logs $p | grep -E "java|Stopping process tracer"; done
```
*Why:* OBI's Java path is its own injected Java agent (TLS/thread context) plus the generic kernel tracer for the network.
*Expect:* `instrumenting process cmd=/opt/java/openjdk/bin/java … type=java`, then `unable to attach java agent … java attach timed out`
and `Stopping process tracer … "security_socket_accept" … not found` — this Docker Desktop kernel has no `CONFIG_SECURITY`
(gotcha #60). No `svc=[springboot/…]` lines. Go (demo 18) traced; Java, Postgres and Redis do not, until Docker Desktop ≥ 4.30.

## Exercise 8 — the OpenTelemetry Java agent (the zero-code path that needs no kernel)

The patch (from the file; `__NAME__` is replaced per Deployment):

```yaml
# Demo 20, Part 3 — the OpenTelemetry Java agent, zero code: a strategic-merge patch applied to each petclinic
# Deployment (demos/20-springboot/javaagent.sh). The agent jar (v2.31.1, 2026-08-23, pinned) is fetched once per
# pod by an init container into an emptyDir, and the JVM loads it through JAVA_TOOL_OPTIONS — no image rebuild.
# The app's own Micrometer→Zipkin export is switched off so the collector does not receive every span twice.
# __NAME__ is replaced by the deployment name (the OTel service.name).
spec:
  template:
    spec:
      volumes:
        - {name: otel-agent, emptyDir: {}}
      initContainers:
        - name: fetch-otel-javaagent
          image: alpine:3.20
          command: [sh, -c, 'wget -qO /otel/opentelemetry-javaagent.jar https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.31.1/opentelemetry-javaagent.jar && ls -l /otel']
          volumeMounts: [{name: otel-agent, mountPath: /otel}]
      containers:
        - name: __NAME__
          volumeMounts: [{name: otel-agent, mountPath: /otel, readOnly: true}]
          env:
            - {name: JAVA_TOOL_OPTIONS, value: "-javaagent:/otel/opentelemetry-javaagent.jar -XX:MaxRAMPercentage=65 -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k"}
            - {name: OTEL_SERVICE_NAME, value: __NAME__}
            - {name: OTEL_RESOURCE_ATTRIBUTES, value: "k8s.cluster.name=poc1,k8s.namespace.name=springboot,k8s.deployment.name=__NAME__"}
            - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: http://otel-collector.otel.svc.cluster.local:4318}
            - {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: http/protobuf}
            - {name: OTEL_METRICS_EXPORTER, value: none}        # traces only here; the demo 16 stack scrapes /actuator/prometheus if wanted
            - {name: OTEL_LOGS_EXPORTER, value: none}
            - {name: MANAGEMENT_ZIPKIN_TRACING_EXPORT_ENABLED, value: "false"}   # Spring Boot 3.4: management.zipkin.tracing.export.enabled
```

```bash
demos/20-springboot/javaagent.sh on
```
*Why:* an init container fetches the pinned jar into an emptyDir; `JAVA_TOOL_OPTIONS` loads it; OTLP goes to the collector;
the app's own Zipkin export is switched off so nothing arrives twice. One Deployment at a time — a patch is a rolling restart,
and six cold JVMs at once would double the memory the VM has left.
*Expect:* six lines `<name> patched; deployment "<name>" successfully rolled out` (10–15 minutes), then in
`kubectl -n springboot logs deploy/api-gateway`: `opentelemetry-javaagent - version: 2.31.1`.

```bash
demos/20-springboot/check.sh 3; sleep 25
kubectl --context kind-poc1 -n otel logs ds/otel-collector --since=2m | demos/18-obi/tracetree.py "GET /api/gateway"
```
*Expect:* a 12-span tree: gateway → customers-service → `OwnerRepository.findById` → `Session.find` → `SELECT …`, and the
visits branch — framework internals no kernel tracer sees.

## Exercise 9 — petclinic on Grafana

The PodMonitor (from `40-monitoring.yaml`; the dashboard ConfigMap follows it in the file):

```yaml
# Demo 20, Part 4 — petclinic on the demo 16 Grafana.
#   PodMonitor: the four application JVMs' /actuator/prometheus (Micrometer). discovery-server answers 404 there and
#   config-server exposes no JVM metrics (neither loads the shared config), so they are not selected.
#   Relabelings give the series what the standard dashboard's variables query: `application` = the pod's app label
#   (Micrometer's own application="petclinic" on two services becomes exported_application, honor_labels is off),
#   `instance` = the pod name, plus node and cluster like every other ServiceMonitor/PodMonitor in this repo.
#   ConfigMap: grafana.com dashboard 19004 "Spring Boot 3.x Statistics", datasource input resolved to the demo 16
#   Prometheus, loaded by Grafana's sidecar exactly like Cilium's dashboards (searchNamespace: ALL, label grafana_dashboard=1).
#   kubectl --context kind-poc1 apply -f demos/20-springboot/40-monitoring.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: petclinic
  namespace: springboot
spec:
  selector:
    matchExpressions:
    - key: app
      operator: In
      values:
      - api-gateway
      - customers-service
      - vets-service
      - visits-service
  podMetricsEndpoints:
  - port: http
    path: /actuator/prometheus
    interval: 15s
    relabelings:
    - sourceLabels:
      - __meta_kubernetes_pod_label_app
      targetLabel: application
      action: replace
    - sourceLabels:
      - __meta_kubernetes_pod_name
      targetLabel: instance
      action: replace
    - sourceLabels:
      - __meta_kubernetes_pod_node_name
      targetLabel: node
      action: replace
    - targetLabel: cluster
      action: replace
      replacement: poc1
---
apiVersion: v1
```

```bash
kubectl --context kind-poc1 apply -f demos/20-springboot/40-monitoring.yaml
sleep 60; demos/20-springboot/check.sh 5; sleep 30
open https://grafana.poc.local/d/springboot-19004/spring-boot-3-x-statistics-petclinic
```
*Why:* Micrometer's `/actuator/prometheus` on the four application JVMs, relabeled so the standard dashboard's `application`
and `instance` variables work; the dashboard arrives through the same sidecar path as Cilium's (a labelled ConfigMap).
The ConfigMap was generated, not hand-written — demo 16 Part 1b and `demos/16-monitoring/dashboard-configmap.sh 19004 springboot
grafana-dashboard-springboot springboot-19004 " (petclinic)" "Spring Boot"` reproduce it.
*Expect:* four `up` targets under Prometheus → Status → Targets (`podMonitor/springboot/petclinic`), and per-service request
rate, latency, heap and GC on the dashboard after a minute of traffic. Traces are **not** in Grafana: there is no trace store
in this lab (README Part 4).

## Exercise 10 — back to normal

```bash
demos/20-springboot/javaagent.sh off                                    # the plain manifest again (delete + re-apply)
kubectl --context kind-poc1 delete -f demos/20-springboot/40-monitoring.yaml -f demos/20-springboot/20-gateway.yaml -f demos/20-springboot/10-petclinic.yaml
sudo sed -i '' '/---- cilium-kind-poc springboot/,/---- end cilium-kind-poc springboot/d' /etc/hosts
demos/20-springboot/scale.sh up
```
*Why:* the JVMs' memory goes back to the bank and demo 09; the collector keeps its zipkin receiver (harmless).
*Expect:* `scale.sh up` prints the demo 15 / demo 09 replica counts and a higher `VM available`.
