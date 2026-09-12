# Demo 23 — a collector per cluster, and why it is not a global service

**Where this sits in the whole:** [OBSERVABILITY-ARCHITECTURE.md](../../OBSERVABILITY-ARCHITECTURE.md) — the one picture of metrics, traces and flows across poc1, poc2 … poc-N, reviewed against what is deployed.

## Summary context

Demo 22 gave poc2 a collector of its own and left its Service global with local affinity, so that
poc2's spans would "fall back" to poc1's collectors if poc2's died. This demo supersedes that part of
demo 22 (demo 22 stays as recorded): the collector is a **per-cluster** platform service, the same
name in every cluster by convention and **not** a global service, with its high availability inside
the cluster — two replicas, a PodDisruptionBudget, and a **persistent queue** so the hub being down
is a delay, not a loss. Everything is recorded in [`output/transcript.txt`](output/transcript.txt).

## The technical justification (measured, Part 1)

The OpenTelemetry gateway pattern is "applications or other Collectors sending telemetry signals to
a single OTLP endpoint" provided by "one or more Collector instances running as a standalone
service", and "typically, an endpoint is provided per cluster, per data center, or per region"
([Gateway deployment pattern](https://opentelemetry.io/docs/collector/deploy/gateway/)). Its
listed costs are the reasons it exists: it is the one place that stamps the cluster identity,
batches, buffers and retries, and it is the single egress point to the backend. Demo 18's
arrangement — poc2's OBI sending straight across the mesh to poc1's collectors — had none of that:
every span crossed the mesh unbuffered, and a mesh or hub outage lost them at the source.

Why the gateway must not be a global service, in three measured facts:

1. **Cluster identity gets stamped wrong.** poc2's gateway inserts `k8s.cluster.name=poc2` on
   anything that arrives without it. OBI spans carry their own cluster name; the OTel Java agent's
   (demo 20) do not. A poc1 span that reaches poc2's gateway is stored as poc2.
2. **With the demo 18 annotation on both sides, each cluster's collector address had SEVEN
   backends** — poc1's five DaemonSet pods and poc2's two gateways (Part 1b, second attempt):

   ```
   poc1 otel-collector 10.11.115.140 … backends as poc1-worker sees them:
     68   10.11.115.140:4318/TCP  ClusterIP  1 => 10.10.0.118:4318/TCP (active)
                                             … 5 => 10.10.4.3:4318/TCP   (active)
                                             6 => 10.20.1.3:4318/TCP    (active)   ← poc2
                                             7 => 10.20.1.41:4318/TCP   (active)   ← poc2
   ```

   Two connections in seven from poc1's applications crossed the mesh, were stamped by poc2's
   gateway, and came back to poc1's Tempo through `tempo-central`. (Before demo 23 started it was
   six: one poc2 replica.)
3. **A cross-cluster fallback hides the failure you want to alert on.** A cluster whose gateway is
   dead should show as a gap in Tempo, not silently route through another cluster's gateway and
   double the mesh traffic while it does.

So: HA for a gateway is in-cluster (replicas, a PodDisruptionBudget, a persistent queue), and the
two global services that remain are the hub's role-named ones from demo 22, `prometheus-remote-write`
and `tempo-central`. This is the demo 22 standard applied to the collector: **applications declare
their own HA with global annotations on their own Services; platform services get role-named,
non-colliding Services, global only where the flow must cross clusters.**

## Part 1 — before

The demo 18 Service on poc1 (global), demo 22's on poc2 (global + affinity local), poc2's collector
at 1 replica with the exporter's defaults: an in-memory queue of 1,000 and retries that stop after
300 s ([exporterhelper](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md):
"`max_elapsed_time` (default = 300s) … If set to 0, the retries are never stopped").

**Part 1b, two attempts.** The first put the annotation back on poc1 only and saw five backends: a
global Service exports a cluster's backends only when *that* cluster's Service is annotated too
(the demo 07 rule, re-learned). The second annotated both and saw the seven above. Then a trap of
`kubectl` itself: an annotation added with `kubectl annotate` is not in `kubectl apply`'s
last-applied record, so a later `apply` of a manifest without it leaves it in place (Part 2c). It
was removed explicitly with `kubectl annotate … service.cilium.io/global-` on both clusters.

## Part 2 — the per-cluster Service, the upgraded gateway, the queue on poc1 too

- [`10-collector-service.yaml`](10-collector-service.yaml): `otel-collector.otel`, no annotation,
  applied to **both** clusters.
- [`20-otel-collector-poc2.yaml`](20-otel-collector-poc2.yaml): 2 replicas, preferred
  anti-affinity, a PodDisruptionBudget (`minAvailable: 1`), the `file_storage` extension on an
  emptyDir, `sending_queue: {storage: file_storage, queue_size: 5000}`,
  `retry_on_failure: {max_elapsed_time: 0}`, the collector's own metrics on `:8888`, the cluster
  stamp (`insert`, so OBI's own stays), OTLP + Zipkin receivers.
- [`demos/10-tracing/otel-collector.yaml`](../10-tracing/otel-collector.yaml) (poc1's DaemonSet,
  additive): the same persistent queue on the hostPath its filelog checkpoint already uses, and the
  `:8888` metrics.

```bash
for c in poc1 poc2; do kubectl --context kind-$c apply -f demos/23-collector-per-cluster/10-collector-service.yaml; done
kubectl --context kind-poc2 apply -f demos/23-collector-per-cluster/20-otel-collector-poc2.yaml
kubectl --context kind-poc1 apply -f demos/10-tracing/otel-collector.yaml && kubectl --context kind-poc1 -n otel rollout restart ds/otel-collector
demos/23-collector-per-cluster/check.sh
```

After (Part 2d, [`check.sh`](check.sh)): poc1's address has its five pods, poc2's its two,
`annotations: global=[] affinity=[]` on both, `poc2: 2/2 ready, PDB: minAvailable=1
allowed-disruptions=1`, every gateway `queue=0 sent=0 failed=0` (fresh).

## Part 3 — the persistent queue, proven

The hub's Tempo scaled to 0 (poc2 sees `tempo-central` with 0 backends), the bank driven with 30
payments (they land on poc2's `accounts`), 20 s later:

```
  otel-collector-…-79qwk   accepted_spans=281 queue_size=2 sent_spans=297
  otel-collector-…-dtdzn   accepted_spans=0   queue_size=0 sent_spans=0
```

(`sent_spans=297` is the first attempt's drain, Part 3: Tempo had been brought back once already.
`queue_size` counts only what no consumer has taken yet; the ten consumers hold the rest in their
retry loops — which is why the first kill attempt found "no pod with a queue". The proof is by
counters instead.) Both collector processes killed from the node with `kill -9` (crictl → pid), the
kubelet restarted both containers in the same pods:

```
  otel-collector-…-79qwk restarts=2 ready=true    accepted_spans=0 queue_size=2 sent_spans=0
  otel-collector-…-dtdzn restarts=1 ready=true    accepted_spans=0 queue_size=0 sent_spans=0
```

Counters restart with the process: nothing new accepted, and the queue re-read from the emptyDir.
Tempo scaled back to 1, 45 s, no new traffic:

```
  otel-collector-…-79qwk   accepted_spans=0 queue_size=0 sent_spans=281
```

**281 spans sent after a restart during which 0 were accepted: they came from the queue on disk,
written before the kill** — exactly the exporterhelper promise, "if the collector instance is
killed while having some items in the persistent queue, on restart the items will be picked and
the exporting is continued". Tempo's search for `k8s.cluster.name="poc2"` over the window returned
38 traces. (`79qwk` shows two restarts: the second is this kill at 13:24:58Z, exit 137; the first
is not in the pod's retained state, and the proof does not depend on it.)

Limits, stated: an emptyDir survives a container restart, not a pod reschedule — a PVC would; and a
queue of 5,000 batches is the budget for an outage, after which "data cannot be added to the
sending queue [and] is typically dropped" (exporterhelper) — size it from the outage you plan for.

## Exercises

See [`GUIDE.md`](GUIDE.md).

## What to take away

- **A gateway per cluster, never global.** Same name everywhere by convention; identity, buffering
  and egress are the cluster's own.
- **The queue is the enterprise difference.** With the defaults, a 5-minute hub outage loses spans
  (retries stop at 300 s) and a restart loses the queue (memory). With `storage` + `max_elapsed_time: 0`
  the outage is a delay.
- **Two `kubectl` traps on the way:** a global service needs the annotation on both sides, and
  `kubectl annotate` bypasses `apply`'s ownership — remove with `annotate key-`.

## Evidence

Captured 2026-09-12 with `scripts/evidence/capture.js` and `scripts/evidence/collect.sh` (both re-runnable; the pod and Cilium output is the recorded file [`output/evidence.txt`](output/evidence.txt)). Every image is what the browser saw, with traffic running.

**Running pods** (from `output/evidence.txt`):

```console
$ kubectl --context kind-poc1 -n otel get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE     IP            NODE                  NOMINATED NODE   READINESS GATES
otel-collector-5qwgc   1/1     Running   0          7h39m   10.10.1.96    poc1-control-plane2   <none>           <none>
otel-collector-7vbhr   1/1     Running   0          7h39m   10.10.4.220   poc1-worker           <none>           <none>
otel-collector-cfgjr   1/1     Running   0          7h39m   10.10.2.196   poc1-control-plane3   <none>           <none>
otel-collector-lntgk   1/1     Running   0          7h39m   10.10.3.58    poc1-worker2          <none>           <none>
otel-collector-xvft4   1/1     Running   0          7h39m   10.10.0.189   poc1-control-plane    <none>           <none>
```

```console
$ kubectl --context kind-poc2 -n otel get pods -o wide
NAME                             READY   STATUS    RESTARTS     AGE   IP           NODE          NOMINATED NODE   READINESS GATES
otel-collector-8f8c6fd76-79qwk   1/1     Running   2 (8h ago)   9h    10.20.1.3    poc2-worker   <none>           <none>
otel-collector-8f8c6fd76-dtdzn   1/1     Running   1 (8h ago)   9h    10.20.1.41   poc2-worker   <none>           <none>
```

The Cilium/kubectl commands that prove this demo's claim, with their output, follow the pod listings in [`output/evidence.txt`](output/evidence.txt).
