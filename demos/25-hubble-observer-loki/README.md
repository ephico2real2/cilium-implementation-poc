# Demo 25 — historical flows, the open-source way: hubble-observer → Loki → the 23862 dashboard

## Summary context

Demo 16 Part 11b established what the flows-per-minute chart in the enterprise screenshots is: Isovalent's
Hubble UI reading **Hubble Timescape**, their flow store. The open-source UI we run has a ring buffer per
node and no store. This demo builds the store from open-source parts and lands on the same picture:
a time range, a flows-per-minute chart, a filterable table of every dropped flow — for **both clusters
through one relay** — in Grafana ([capture](output/screenshots/ho-dashboard.png)).

| Piece | What | Where |
|---|---|---|
| the source | [onzack/hubble-observer](https://github.com/onzack/hubble-observer) (Apache-2.0): one pod running `hubble observe flows --verdict DROPPED --follow -o json` against the relay, one JSON flow per line on stdout | poc1, namespace `hubble-observer` |
| the shipper | the demo 10 OTel collector DaemonSet, a second `filelog` receiver on that pod's log file only, resource attributes named as the dashboard expects, `otlphttp` to Loki's OTLP endpoint with the demo 23 persistent queue | poc1, `otel` |
| the store | Grafana Loki 3.6.12, single binary, filesystem, 24 h retention, the three attributes as index labels | poc1, `monitoring` |
| the view | grafana.com dashboard **23862 rev 5** (the chart's own), provisioned as a sidecar ConfigMap in the Hubble folder; cf2cnp behind the demo 09 Gateway for the dashboard's link | Grafana |

Everything is recorded in [`output/transcript.txt`](output/transcript.txt). **Answers to the three questions
that shaped it:**

- **poc1 only, or every cluster?** poc1 only. Since demo 24 poc1's relay streams all 7 nodes of the mesh
  (`Connected Nodes: 7/7` as the observer sees it, Part 5), and every flow carries
  `source.cluster_name` / `destination.cluster_name` — the dashboard's *Source Cluster* / *Destination
  Cluster* boxes filter on exactly those. Part 3b proves it: a drop caused in poc2 is stored labelled
  `poc2`, reported by `poc2/poc2-worker`. The per-cluster alternative (an observer and a shipper in every
  cluster, all writing to the central Loki, the demo 22/23 shape) is the right one when relays are not
  meshed or the relay stream would cross a WAN; here it would double the pods to say the same thing.
- **The embedded dashboard the chart creates?** It is a `GrafanaDashboard` custom resource for the
  Grafana **Operator**, which this stack does not run — our Grafana is fed by the kube-prometheus-stack
  sidecar from ConfigMaps (demo 16). So `grafanaDashboard.enabled: false`, and
  [`dashboard-from-file.sh`](dashboard-from-file.sh) makes the same substitutions the chart's template
  makes (`DS_LOKI` → the dashboard's own `${datasource}` variable, the observer namespace, the cf2cnp URL)
  and wraps the downloaded export in a ConfigMap with the `grafana_folder: Hubble` annotation.
- **TLS / mTLS to the relay?** Our relay runs `disable-server-tls: true` (measured, Part 2), so the
  observer connects in plaintext on port 80 and the README's TLS section does not apply *yet*. Part 5
  states how it applies on this stack — a client certificate from the demo 08 issuer — and why it was not
  switched on today.

## Part 0 — chart-prep.sh: the critical first step, every chart, every time

[`chart-prep.sh`](chart-prep.sh) does, and records, the four steps in order: **(1)** add the source
(`helm repo add grafana …`; the onzack charts live in an OCI registry, which has no `repo add`),
**(2)** list the versions available and pick one on purpose (`helm search repo grafana/loki --versions`;
for ghcr.io the tags list through an anonymous pull token), **(3)** pull *that* version's default values
into [`default-values/`](default-values/) — committed, the baseline — and **(4)** diff our values
against them, key by key. Recorded:

```
  grafana/loki (newest 5): chart 7.3.0 app 3.6.12 · 7.2.0 · 7.1.0 · 7.0.0 · 6.55.0
  oci://ghcr.io/onzack/helm-charts/hubble-observer tags: 0.6.1 … 2.4.2 2.5.0 2.6.0-alpha
  oci://ghcr.io/onzack/helm-charts/cf2cnp tags: 0.1.0 0.3.1 0.4.0
  default-values/loki-7.3.0.yaml (4441 lines) · hubble-observer-2.5.0.yaml (133) · hubble-observer-2.6.0-alpha.yaml (160) · cf2cnp-0.4.0.yaml (116)
  values-loki.yaml: 27 keys set, e.g. ≠ deploymentMode: 'SingleBinary' (default: 'SimpleScalable') … ≠ read.replicas: 0 (default: 3)
  values-hubble-observer.yaml: 17 keys set, e.g. ≠ grafanaDashboard.enabled: False (default: True) · ≠ cf2cnp.enabled: True (default: False)
```

[`values-loki.yaml`](values-loki.yaml) and [`values-hubble-observer.yaml`](values-hubble-observer.yaml)
carry, on every key, what the default was and why it changed.

## Part 1 — Loki

`helm install loki grafana/loki --version 7.3.0 -n monitoring -f values-loki.yaml`: `loki-0 2/2 Running`,
Service `loki :3100`, `ready`. Single binary, filesystem, replication 1, one tenant, 24 h retention with
the compactor, 512 Mi limit; the SimpleScalable pools, gateway, caches, canary and test off. The one
setting that makes the dashboard work unchanged is Loki's `otlp_config`: the resource attributes
`namespace`, `container` and `k8s.cluster.name` become **index labels**, because the dashboard's every
query starts with `{namespace="…", container="hubble-observer"}` (Promtail's label names, not OTel's).

## Part 2 — the observer, and the published chart's bug

`helm install … oci://…/hubble-observer --version 2.5.0`: `--wait` failed with `context deadline
exceeded`; the pod sat at `0/1 Running`, restarts climbing, no output. Its events:

```
Startup probe failed: failed to connect to 'hubble-relay:80': … lookup hubble-relay on 10.11.0.10:53: no such host
Killing  Container hubble-observer failed startup probe, will be restarted
```

By hand, from inside the same pod: `hubble status --server hubble-relay.kube-system.svc.cluster.local:80`
→ `Connected Nodes: 7/7`. The container worked; the probe killed it. **The 2.5.0 chart's three probes
dial `$(HUBBLE_RELAY_HOST):$(HUBBLE_RELAY_PORT)`, the short name, while the observe command uses the
FQDN** — a short name resolves only from the relay's own namespace (gotcha #73). The main branch builds
one FQDN for both (`_helpers.tpl`, `relayAddress`), so the chart is **vendored from main** at
[`chart/hubble-observer`](chart/hubble-observer) (commit in [`chart/UPSTREAM-COMMIT.txt`](chart/UPSTREAM-COMMIT.txt),
also published as tag `2.6.0-alpha`; `helm dependency build` pulled the cf2cnp 0.4.0 subchart).

**Part 2b**, reinstalled from it: both pods `1/1 Running`, `probe target now:
hubble-relay.kube-system.svc.cluster.local:80`. cf2cnp on, exposed as every app here is
([`20-cf2cnp-route.yaml`](20-cf2cnp-route.yaml): the HTTPRoute in the Gateway's namespace, since its
listeners admit routes from `Same` only, and a ReferenceGrant in `hubble-observer`) — `cf2cnp
[cf2cnp.poc.local] Accepted True ResolvedRefs True`; [`hosts-entries.sh`](hosts-entries.sh) prints the
`/etc/hosts` line for the Mac.

## Part 3 — the shipper, and the drops

[`../10-tracing/otel-collector.yaml`](../10-tracing/otel-collector.yaml), additive: a `filelog/hubble-observer`
receiver on `/var/log/pods/hubble-observer_hubble-observer-*/hubble-observer/*.log` with the `container`
operator (the path becomes `k8s.namespace.name` / `k8s.container.name` / `k8s.pod.name`), a
`resource/loki-labels` processor inserting `namespace`, `container` and `k8s.cluster.name=poc1`, an
`otlphttp/loki` exporter with the persistent queue, and the `/var/log/pods` hostPath. Only that pod's
files: the DaemonSet does not become a general log shipper.

Drops on purpose: demo 19's cell probe (`egress-test.sh`) — `api.stripe.com:80` (FQDN allowed on 443 only),
`example.com:443`, `1.1.1.1:443`, the API server, `echo.routes`, `api.bank:8080` — all `DENIED`. 45 s later:

```
  observer stdout:  {"flow":{"time":"…","verdict":"DROPPED","drop_reason":133, … 
  Loki index labels: container k8s_cluster_name k8s_container_name k8s_namespace_name k8s_pod_name namespace service_name
  Loki streams for {namespace="hubble-observer",container="hubble-observer"}: 1
  Loki, last 10 min, by verdict and source cluster:  {flow_source_cluster_name: poc1, flow_verdict: DROPPED} 68
```

The **api.stripe.com and example.com rows on the dashboard are that test traffic**, nothing else.

**Part 3b — one observer, both clusters.** The first attempt to cause a drop from a poc2 bank pod
failed: `exec: "sh": executable file not found` — the bank images are distroless (gotcha #74). The
demo 19 way, a debug pod in poc2's `bank` namespace, three `wget http://1.1.1.1` → `rc=1` each; 45 s later:

```
  {flow_node_name: poc2/poc2-worker, flow_source_cluster_name: poc2, flow_source_pod_name: egress-probe} 12
```

A drop observed by a poc2 agent, streamed by poc1's relay across the mesh, stored in poc1's Loki labelled
`poc2`.

## Part 4 — Grafana

The Loki data source added to the demo 16 stack values (`additionalDataSources`, `uid: loki`), the
dashboard ConfigMap applied. Through the Grafana API: `ds: Loki loki http://loki.monitoring…:3100`;
`dashboard: Cilium Flows - Hubble Observer | folder: Hubble | uid: hubble-observer-23862`; the
dashboard's own Total Flows query through the data source proxy: **68**, then 80 with poc2's.

The [capture](output/screenshots/ho-dashboard.png) ([`browser-check.js`](browser-check.js)): *Total
Flows 80*, *Flows per Verdict* DROPPED, *Flows per Source Namespace* bank 100 %, *Flows per Destination*
api.bank 29 % · echo.routes 29 % · api.stripe.com 21 % · example.com 21 %, the flows-per-minute bars at
09:45–09:51, and the table's newest rows: `10.20.1.157 egress-probe (Pod) bank EGRESS TCP-80` — poc2's
probe, first. Zero "No data" panels. Two facts about the capture: the panels took **minutes** to render
on this VM (load 160–190 through the afternoon, the gotcha #66 environment; Loki's own log reports every
query `latency=fast` and Grafana's only errors are `context canceled` from the page closing), so the
script waits for the Total Flows number rather than a fixed time; and Chromium resolves `cf2cnp.poc.local`
itself (`--host-resolver-rules`) so the capture needs no `sudo`. The [cf2cnp UI](output/screenshots/ho-cf2cnp.png):
`POST /generate`, `GET /download/{id}`, `GET /health` → `OK` through the Gateway.

## Part 5 — TLS and mTLS to the relay, on this stack (documented, not applied)

The chart's README: with `hubble.relay.tls.server.enabled=true` the observer must speak TLS; with
`mtls=true` it needs "a client certificate signed by the Cilium CA", and the secrets must be in the
observer's namespace. Our relay: `disable-server-tls: true`, Service port 80 → plaintext (Part 2).
Since demo 24 the CA that signs the relay's certificates is the demo 08 cert-manager root, so the
enterprise answer is not to copy `hubble-relay-client-certs` across namespaces but to **issue the
observer its own client certificate from `ClusterIssuer/ca-issuer`** —
[`30-relay-mtls-client-cert.yaml`](30-relay-mtls-client-cert.yaml), with the values it needs in its
header. Not applied today because enabling the relay's server TLS turns every plaintext relay client in
this repo (`hubble status` port-forwards in `verify.sh`, `check.sh`, demos 16–24) into a TLS client in
one move; it belongs in a window with those scripts updated. The chart's `ciliumNetworkPolicy` stays off
for a measured-by-reading reason: its policy allows egress to the relay only, no DNS rule, so with it on
the pod could not resolve the relay's name (an exercise in the GUIDE).

## Exercises

See [`GUIDE.md`](GUIDE.md).

## What to take away

- **Timescape is a store plus a UI; the store is the part you can build.** Exporter or observer → a
  shipper → Loki gives the time range, the histogram and the searchable history. The service map over a
  time range stays enterprise.
- **One relay, both clusters** — because demo 24 put Hubble on the shared CA. Without it, this demo
  would have needed an observer per cluster.
- **Pull the defaults first.** `chart-prep.sh` is the habit: the versions, the default values of the
  one you chose, and your values as a diff against them — that is what turned a "the pod is broken"
  into "the published chart's probe is wrong" in one read of the template.
- **Labels are the contract.** The dashboard's `{namespace, container}` came from Promtail; the
  collector and Loki were configured to honour it, rather than editing nine queries.
