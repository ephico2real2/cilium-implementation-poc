# Demo 10 — Flow tracing: Hubble export → OpenTelemetry

> **Where this sits in the whole:** [OBSERVABILITY-ARCHITECTURE.md](../../OBSERVABILITY-ARCHITECTURE.md) — the one picture of metrics, traces and flows across poc1, poc2 … poc-N, reviewed against what is deployed.

## Summary context — and an honest reframing

**What was planned.** "Tracing" in the original programme meant Hubble flows turned into
OpenTelemetry *spans* via `hubble-otel`, so network events could sit in the same backend as
application traces.

**What research found before anything was built.**

- **`cilium/hubble-otel` is archived.** *"This repository was archived by the owner on Jun 20,
  2024. It is now read-only ... archived and unmaintained."*
- **The CFP for Envoy-side OpenTelemetry tracing, cilium/cilium#41259, is closed as not
  planned.** Its own motivation names the gap: *"With hubble-otel no longer being maintained, it
  has become harder to get observability for L7 traffic in Cilium environments."*

**So Cilium 1.20 does not emit application spans, and this demo does not pretend otherwise.**

**What it does instead — and it is genuinely useful.** Cilium's maintained, built-in **Hubble flow
export** writes every flow as newline-delimited JSON — identities, verdicts, L4/L7 detail,
timestamps — to a per-node file with rotation, and its *dynamic* mode changes filters **without a
restart**. An OpenTelemetry Collector tails that file and emits each flow as an OTLP **log
record**. That gives you:

- a **persistent, queryable** record of every flow, which removes demo 01's hard limit (Hubble's
  ring buffer was 94% full and recycling within minutes);
- **correlation** by timestamp, pod and identity against whatever application traces you have
  from elsewhere, in the same OTLP-speaking backend;
- an integration point where **any** backend — Loki, Elastic, Splunk, Grafana Cloud — is one
  exporter block away.

These are **events, not spans**. For runtime process/syscall tracing, the sibling project is
**Tetragon** — a separate install and a different story.

All output is in [`output/transcript.txt`](output/transcript.txt).

---

## Part 1 — enable dynamic export

`cilium/values-hubble-export.yaml` configures three exports from one flow stream:

| Name | File | Filter | Purpose |
|---|---|---|---|
| `all` | `events.log` | none, fieldMask trims each record | everything |
| `drops` | `drops.log` | `verdict: [DROPPED]` | "every policy denial ever" |
| `http` | `http.log` | `protocol: [http]` | an L7 request log — **added later, live** |

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 \
  --reuse-values -f cilium/values-hubble-export.yaml
kubectl -n kube-system rollout restart daemonset/cilium      # the FIRST enable needs one restart
```

Twenty seconds later, on every node:

```
poc1-worker    435152 events.log
poc1-worker2   278 drops.log  440606 events.log
```

The files live at `/var/run/cilium/hubble/` **on the node** — a hostPath, verified against the
cilium DaemonSet's `cilium-run` volume — which is what makes them readable by another pod.

**Each node writes only the flows it saw.** That sentence decides the collector's architecture.

## Part 2 — the collector

`otel-collector.yaml`: a **DaemonSet** (one file per node means one reader per node), `filelog`
receiver → `json_parser` → `debug` exporter.

```bash
kubectl apply -f demos/10-tracing/otel-collector.yaml
```

The first attempt crash-looped on every node:

```
Error: cannot start pipelines: failed to start "filelog" receiver:
       storage client: open /var/lib/otelcol/receiver_filelog_: permission denied
```

The contrib image runs as uid 10001; kubelet creates a `DirectoryOrCreate` hostPath as
`root:root 0755`. The export file itself turned out to be `0644` (readable), so only the
**checkpoint write** needed root — but it did need it. `runAsUser: 0` is the same decision
fluent-bit, promtail and vector make in this role, and the manifest says so rather than hiding it.

```
otel-collector-94j75   1/1   Running     (x5, one per node)
```

**Why `debug` and not Jaeger or Loki.** The claim under test is the *integration* — Hubble → file →
Collector → OTLP. The debug exporter prints every record to the collector's log, proves the pipeline
on a laptop, and costs nothing. A real backend changes the `exporters:` block and nothing else.

## Part 3 — one flow, followed end to end

Generate three kinds of flow with demo 02's app:

```bash
kubectl exec tiefighter -- curl -XPOST deathstar.default.svc.cluster.local/v1/request-landing   # L7 allowed
kubectl exec tiefighter -- curl -XPUT  deathstar.default.svc.cluster.local/v1/exhaust-port      # L7 denied → 403
kubectl exec xwing      -- curl -XPOST deathstar.default.svc.cluster.local/v1/request-landing   # L3 denied → drop
```

**On the node** (`events.log`, the deathstar pod's node):

```
16:17:07.832 FORWARDED tiefighter -> deathstar-6wgwz POST /v1/request-landing
16:17:07.910 FORWARDED deathstar-6wgwz -> tiefighter POST /v1/request-landing code=200
16:17:08.231 DROPPED   tiefighter -> deathstar-6wgwz PUT  /v1/exhaust-port
16:17:08.233 FORWARDED deathstar-6wgwz -> tiefighter PUT  /v1/exhaust-port code=403
```

**In the collector**, the same flow as an OTLP record — timestamp preserved to the nanosecond:

```
LogRecord #23
Timestamp:         2026-09-11 16:17:08.231496853 +0000 UTC     <- the flow's own time
ObservedTimestamp: 2026-09-11 16:17:08.368682895 +0000 UTC     <- when the collector saw it: 137 ms later
Body: Str({"flow":{"time":"2026-09-11T16:17:08.231496853Z","verdict":"DROPPED", ...
     -> flow: Map({... "Summary":"HTTP/1.1 PUT http://deathstar.default.svc.cluster.local/v1/exhaust-port" ...})
     -> k8s.node.name: Str(poc1/poc1-worker)
     -> hubble.verdict: Str(DROPPED)
```

522 records emitted by that one collector in two minutes. The 137 ms between `Timestamp` and
`ObservedTimestamp` is the file-tail pipeline latency, measured for free.

### The drop that was on the "wrong" node

The xwing L3 denial was **not** in the deathstar pod's node's `drops.log`. It was on
`poc1-worker2`, 8 times:

```
time       : 2026-09-11T16:17:11.618328534Z
verdict    : DROPPED / POLICY_DENIED
source     : default / xwing
destination: default / deathstar-d7f446dc5-dkgqt
l4         : {"TCP": {"source_port": 53402, "destination_port": 80, "flags": {"SYN": true}}}
node_name  : poc1/poc1-worker2
```

```
deathstar-d7f446dc5-6wgwz   10.10.4.248   poc1-worker
deathstar-d7f446dc5-dkgqt   10.10.3.231   poc1-worker2
xwing                       10.10.4.63    poc1-worker
```

xwing is on `poc1-worker`. The Service load-balanced its SYN to the replica on **worker2**, and
ingress policy is enforced at the **destination** — so that is where the drop was logged.
**A drop is recorded by the node that enforced it, which for a load-balanced Service is not
necessarily the node you expect.** This is exactly why the export must be read from every node.

## Part 4 — the "dynamic" claim, measured

The `http` export was added **after** the other two were live: a change to the overlay, a
`helm upgrade`, and **no DaemonSet restart**.

```
helm history:  REVISION 15   (pods before and after: identical — cilium-2d74m cilium-lwmn7 ...)
agent log:     16:19:22  "Configuring Hubble event exporter" flowLogName=http
```

```
poc1-worker    5148 drops.log   4906749 events.log   1315 http.log
http.log lines=2 without_l7=0                                        <- L7-only, as filtered
```

**Honest timing:** the helm upgrade landed at ~16:18; the agent applied it at 16:19:22; a check at
+30 s found nothing. **"Dynamic" means about a minute, not seconds** — a mounted ConfigMap
propagates on kubelet's sync period. The first draft of the overlay comment said "within seconds";
it was wrong and has been corrected. What is true and valuable: **no pod restarted**, so no flow
was lost while the export set changed.

## Part 5 — the question the ring buffer could not answer

Every `POLICY_DENIED` across **all** nodes, ever, from the persistent files:

```bash
for n in poc1-control-plane poc1-control-plane2 poc1-control-plane3 poc1-worker poc1-worker2; do
  docker exec $n cat /var/run/cilium/hubble/drops.log
done | python3 -c '...'   # see the transcript
```

```
8 x ('xwing', 'deathstar-d7f446dc5-dkgqt', 'poc1/poc1-worker2')
```

In demo 01 that history was gone within minutes. Here it persists, rotates predictably
(`fileMaxSizeMb: 10`, `fileMaxBackups: 5`), and any log backend can index it.

## What to take away

| Claim | Evidence |
|---|---|
| Cilium 1.20 provides flow export, not spans | hubble-otel archived 2024-06-20; CFP #41259 closed |
| Every flow is persisted per node | `events.log` on 5 nodes, 4.9 MB within minutes |
| The pipeline is end to end | flow `16:17:08.231` in file → `LogRecord #23`, timestamp preserved |
| Latency is visible | `ObservedTimestamp − Timestamp` = 137 ms |
| Filters change without a restart | `http.log` appeared, pods unchanged — in ~1 min, not seconds |
| Drops are logged where enforced | xwing's drop on worker2, the destination replica's node |
| Any backend plugs in | `exporters:` block; receiver side unchanged |

## Clean up

```bash
kubectl delete -f demos/10-tracing/otel-collector.yaml
# to stop exporting: set hubble.export.dynamic.enabled=false in the overlay and helm upgrade
```

## Addendum (2026-09-11) — the error that looks like lost data, and the socket that looks like lost L7

Two traps met while checking "is tracing still working?", both documented with measurements in
GOTCHAS #35 and #36 and recorded in `output/transcript.txt`:

- Every collector logged `failed to emit token … field does not exist: attributes.flow.verdict`.
  Cause: ~1 % of `events.log` lines are `agent_event` records with no `flow`; the `move` operator
  failed on them but still forwarded them. Fix in `otel-collector.yaml`: `if: 'attributes.flow != nil'`
  on the move, then `rollout restart ds/otel-collector`. After: 0 errors, records unchanged.
- `hubble observe --protocol http` from inside an agent pod returned nothing while L7 policy was
  visibly enforcing. It reads that node's socket only; L7 flows are on the proxy's node. Use the
  relay (`cilium hubble port-forward`, then `hubble observe`) — 418 HTTP flows in 10 min.
- And on the laptop itself, `hubble observe` with no port-forward at all is `connection refused` on
  `127.0.0.1:4245` — gotcha #37; `hubble observe -P --since 5m --protocol http` is the one-liner.

> **Added in demo 18.** The collector now also has an `otlp` receiver (4317/4318) and a `traces`
> pipeline to the same `debug` exporter, and is exposed as a global Service
> (`demos/18-obi/20-collector-service.yaml`) so OBI in both clusters sends its spans here. The
> logs pipeline and everything above are unchanged.

## Evidence

Captured 2026-09-12 with `scripts/evidence/capture.js` and `scripts/evidence/collect.sh` (both re-runnable; the pod and Cilium output is the recorded file [`output/evidence.txt`](output/evidence.txt)). Every image is what the browser saw, with traffic running.

**Running pods** (from `output/evidence.txt`):

```console
$ kubectl --context kind-poc1 -n otel get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE     IP            NODE                  NOMINATED NODE   READINESS GATES
otel-collector-5qwgc   1/1     Running   0          7h38m   10.10.1.96    poc1-control-plane2   <none>           <none>
otel-collector-7vbhr   1/1     Running   0          7h39m   10.10.4.220   poc1-worker           <none>           <none>
otel-collector-cfgjr   1/1     Running   0          7h38m   10.10.2.196   poc1-control-plane3   <none>           <none>
otel-collector-lntgk   1/1     Running   0          7h39m   10.10.3.58    poc1-worker2          <none>           <none>
otel-collector-xvft4   1/1     Running   0          7h39m   10.10.0.189   poc1-control-plane    <none>           <none>
```

The Cilium/kubectl commands that prove this demo's claim, with their output, follow the pod listings in [`output/evidence.txt`](output/evidence.txt).

