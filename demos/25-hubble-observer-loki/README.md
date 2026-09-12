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
- **TLS / mTLS to the relay?** Done in Part 5, after measuring why: the relay ran in plaintext
  (`disable-server-tls: true`) and any pod could stream every flow of both clusters from it. Now the
  relays require mutual TLS from the enterprise root; the observer, the UI and the CLI each hold their
  own certificate from cert-manager.

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

## Part 5 — TLS and mTLS to the relay: why, and done

**Why (Part 5a, measured).** The relay is the one API that streams *every* flow of the mesh — both
clusters, every namespace, DNS names and HTTP paths included. With `disable-server-tls: true` it
listened in plaintext on port 80, and any pod that could open a TCP connection to it got all of it:

```
a pod named anyone, namespace default, no ServiceAccount permissions, no certificate:
  Healthcheck (via hubble-relay.kube-system.svc.cluster.local:80): Ok
  Connected Nodes: 7/7
  … 10.20.1.24:56432 (host) -> bank/accounts-6544fcc9b8-jkxgc:8080 … FORWARDED      ← poc2's bank, from poc1's default namespace
```

That is a read of the whole platform's traffic metadata from the least-privileged place in it — the
enterprise reason the chart's README has a TLS section at all. Network policy could fence the relay,
but the relay's own answer is mutual TLS: it presents a certificate from the enterprise root (demo 24)
and requires one from every client. Cilium's own clients — the UI's backend, and the CLI — already
carry that; the observer and the operators needed theirs.

**5b — the observer's own certificate.** [`30-relay-mtls-client-cert.yaml`](30-relay-mtls-client-cert.yaml):
a cert-manager `Certificate` in the observer's namespace from `ClusterIssuer/ca-issuer` — `Ready` in
seconds, `CN=hubble-observer.hubble-relay-client.cilium.io`, `issuer=CN=clustermesh-root-ca`, `TLS Web
Client Authentication`, and `ca.crt` = the root (`72:16:61:3E…`). No Cilium secret copied across a
namespace boundary, which is what the chart's README would otherwise have you do.

**5c — the relays, both clusters, from the declared values.** Three lines added to demo 24's
[`poc1.yaml`](../24-clustermesh-enterprise/poc1.yaml) / `poc2.yaml`: `hubble.relay.tls.server.enabled: true`,
`mtls: true`. Rendered first (the lesson of gotcha #72): `hubble-relay-config` gains the server cert and the
client CA and loses `disable-server-tls`, the relay Service moves **80 → 443**, `Certificate/hubble-relay-server-certs`
(and on poc1 `hubble-ui-client-certs`) are created, `hubble-ui`'s backend gets `TLS_TO_RELAY_ENABLED`
and the client cert — and **`clustermesh-apiserver` is untouched**. Applied with a bank call every
second: `225×200`, no disruption (the pods' start times confirm the mesh API server never moved).
The anonymous pod afterwards: plaintext → exit 1; TLS without a certificate →
`remote error: tls: certificate required`.

**5d — the observer over mTLS.** [`values-hubble-observer.yaml`](values-hubble-observer.yaml): `port: "443"`,
`tls.enabled`, the one secret for `ca` and `client`. The chart mounts it and sets `HUBBLE_TLS=true`,
`HUBBLE_TLS_SERVER_NAME=hubble.hubble-relay.cilium.io`, the CA and client cert paths — which is how its
probes work too. `Connected Nodes: 7/7` from inside the pod.

**5e — operators.** [`40-hubble-cli-client-cert.yaml`](40-hubble-cli-client-cert.yaml): a 90-day client
certificate for the CLI (`CN=operator.hubble-relay-client.cilium.io`, cert-manager renews it) in both
clusters; [`scripts/hubble-tls.sh <context>`](../../scripts/hubble-tls.sh) fetches it into `.tmp/` and
prints the flags. Recorded: `hubble status --server localhost:4245 $(scripts/hubble-tls.sh kind-poc1)` →
`Connected Nodes: 7/7`; without the flags → `error reading server preface: EOF`; `hubble status -P` with
them → 7/7. Every relay client script in the repo now uses it — `scripts/verify.sh`, demo 19's
`drops.sh`, demo 24's and this demo's `check.sh` (`check-routes.sh` reads the agent's local socket and
needed nothing).

**5f — after.** The first check found 0 drops for a reason that had nothing to do with TLS: demo 19's
probe pod had finished its `sleep 3600` (phase `Succeeded`). Recreated: `68 DENIED` lines → observer
stdout 68 lines → `drops.sh` over mTLS 68 (`egress-test@poc1 -> reserved:world :80 POLICY_DENIED 24`, …)
→ Loki `{poc1, DROPPED} 68`. Hubble UI over mTLS ([capture](output/screenshots/ho-ui-tls.png)): 7/7
nodes, 144.9 flows/s, both clusters' bank services on one map, its backend logging `initialized with
TLS to hubble-relay enabled`.

**5g — should this have been day one? Yes, and now it is.** Two facts made the rearrangement
cheap. First, the chart's *Helm* certificate method issues the relay's server certificate, the UI's
client certificate and `hubble-relay-client-certs` at the very first install when
`hubble.relay.tls.server.enabled/mtls` are set — rendered with the day-one file alone:
`Secret hubble-relay-server-certs [ca.crt tls.crt tls.key]`, relay config with the server cert and
without `disable-server-tls`, `Service hubble-relay port 443`. Step 9.3a / demo 24 then re-issues all
of them from the enterprise root with nothing else to change. So the two keys now live in
[`cilium/values-poc1.yaml`](../../cilium/values-poc1.yaml) and `values-poc2.yaml` (the live releases
already carried them from Part 5c — `helm get values` shows `{enabled: True, mtls: True}` on both).
Second, the Hubble CLI has a configuration file with precedence *flag > environment > config file >
default*, so `scripts/hubble-tls.sh --configure kind-poc1 kind-poc2` writes `tls`, `tls-server-name`,
`tls-ca-cert-files` (every listed cluster's CA — one root after demo 24, two before demo 08) and the
client certificate once, and **demos 01–24's commands work as written**. Recorded, verbatim and with no
flags: demo 01's `hubble status -P --kube-context kind-poc1` → `Connected Nodes: 7/7`; demo 07's
`hubble observe -P --kube-context kind-poc2 --last 3` → poc2's flows; a plain `hubble status` through a
`4245:443` port-forward → 7/7. Before cert-manager exists (a fresh build at Step 5) the helper falls
back to the chart's `hubble-relay-client-certs`, which the relay accepts because it verifies clients
against its CA only. The earlier demos stay as recorded; the root README says this once (8b), SETUP
Steps 5, 6 and 9 carry it.

**What did not change:** the observer's `ciliumNetworkPolicy` stays off (its policy has no DNS rule;
GUIDE exercise 6).

## Part 6 — the second pass upstream: two issues, one comment, one pull request

A second pass over the chart with `git log`, the published 2.5.0 templates and a live run of every
switch, recorded in the transcript (Parts 6–6c):

| Finding | Evidence | Upstream |
|---|---|---|
| 2.5.0's three probes dial the relay's **short** name; fixed on `main` by 0246a9a (the TLS commit) but only published as `2.6.0-alpha` | Part 2 (events, `no such host`; `7/7` from inside the same pod) | [issue #7](https://github.com/onzack/hubble-observer/issues/7) |
| the maintainer wrote the TLS/mTLS support and, in their words, has no environment to test it | Part 5d: the observer over mTLS, 68 flows end to end | [comment on #6](https://github.com/onzack/hubble-observer/issues/6#issuecomment-5647503591) |
| `ciliumNetworkPolicy.enabled=true` never worked: **no DNS rule** — Hubble: `<> coredns:53 Policy denied DROPPED`, probes time out, restarts 3 | Part 6, live, then reverted | [issue #8](https://github.com/onzack/hubble-observer/issues/8) |
| …and with DNS fixed, still not Ready: **58 drops to the relay pod `:4245`** — the rule names the *Service* port (80/443); Cilium enforces egress on the **backend pod's** port (gotcha #76) | Part 6b (fork branch, first fix) | [comment on #8](https://github.com/onzack/hubble-observer/issues/8#issuecomment-5647561846) |
| the fix, parameterized: `ciliumNetworkPolicy.dns` (namespace, matchLabels, port, L7 DNS rule, on by default) and `ciliumNetworkPolicy.relayPort` (default 4245); `dns.enabled=false` keeps the old single rule | `helm lint` clean; `helm template` both shapes; `kubectl apply --dry-run=server` created; live: policy on → `READY true, RESTARTS 0`, 0 drops, DNS and relay:4245 `FORWARDED`, `7/7` (Part 6c) | [PR #9](https://github.com/onzack/hubble-observer/pull/9), `Closes #8` |

The fork is `ephico2real2/hubble-observer`, branch `fix/cnp-dns-egress`, one commit authored by the
operator. Our vendored chart stays at upstream `main` (21319b7) with the policy off in our values
until the PR lands; the live cluster was returned to that state after each test (revision 8).

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
- **The relay is the crown jewels of observability.** Everything Hubble sees, one gRPC stream; a
  plaintext relay is an anonymous read of the platform. mTLS from the one root, each client with its
  own certificate, is the standard — and it cost the bank nothing (225×200).
- **Labels are the contract.** The dashboard's `{namespace, container}` came from Promtail; the
  collector and Loki were configured to honour it, rather than editing nine queries.
