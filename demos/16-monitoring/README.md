# Demo 16 — Prometheus + Grafana (kube-prometheus-stack), then Hubble's metrics on dashboards

## Summary context

Hubble UI is a *service map*: it draws flows from each agent's ring buffer (gotcha #47) and has
**no metrics view in any version**. The numbers Hubble produces — drops, DNS, TCP, HTTP/gRPC
latency, per-port distribution — have been on every agent's `hubble-metrics :9965` since demo 01
(`hubble.metrics.enabled` in `cilium/values-poc1.yaml`), but nothing collected them and nothing drew
them. This demo fixes that in two deliberately separate sections:

| Section | What | Why separate |
|---|---|---|
| **A** (this part) | Install **kube-prometheus-stack** on poc1: Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics — and put Grafana on the demo 09 Gateway as `https://grafana.poc.local` | A general-purpose monitoring stack is a platform decision that has nothing to do with Cilium. It must be up, scraping, and reachable **before** Cilium is told to publish into it, or a Cilium-side failure and a stack-side failure are indistinguishable |
| **B** (Part 5 onward) | Tell the Cilium chart to create ServiceMonitors + Grafana dashboards for the agent, the operator and Hubble; prove Prometheus scrapes `:9965`; drive the bank and read the panels | This is the actual answer to *"where are the Hubble dashboards?"* — and it is a Cilium helm change on a live mesh, which has its own blast radius (gotcha #42) |

Everything below was run and recorded in [`output/transcript.txt`](output/transcript.txt).

---

# Section A — the monitoring stack

## Part 1 — install kube-prometheus-stack, pinned, with every deviation explained

**Why this chart.** kube-prometheus-stack is the Prometheus community's packaging of the
Prometheus Operator plus the exporters and Grafana, wired together. Its operator watches
`ServiceMonitor`/`PodMonitor` objects, which is exactly the interface the Cilium chart speaks in
Section B (`hubble.metrics.serviceMonitor.enabled`), so nothing has to be hand-written into a
scrape config. Version pinned to what `helm search` returned on build day, like every other
component in this repo (gotcha #43 — pin, or the next run is a different demo):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts   # the chart's home
helm repo update prometheus-community
helm search repo prometheus-community/kube-prometheus-stack --version 90.1.1            # chart 90.1.1 = operator v0.93.1
```

**The values file** — [`values-kube-prometheus-stack.yaml`](values-kube-prometheus-stack.yaml).
Read it; every key is a deviation from the chart default with its reason in the comment. The ones
that matter:

| Key | Set to | Reason |
|---|---|---|
| `prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues` | `false` | **The trap.** By default Prometheus selects *only* ServiceMonitors carrying the release's own label (`release: monitoring`). The Cilium chart creates its ServiceMonitors in `kube-system` without that label, so with the default they would exist and never be scraped. `false` = select every ServiceMonitor in the cluster |
| `…podMonitorSelectorNilUsesHelmValues` | `false` | same, for PodMonitors |
| `…retention` / `resources` | `2d`, 512 Mi–1 Gi | a laptop lab on a 15 GB VM already running 7 nodes |
| `…enableFeatures: [exemplar-storage]` | on | Hubble's `httpV2` metrics are configured with exemplars (demo 01 values); Prometheus discards them unless this is on |
| `grafana.adminPassword` | `poc-grafana` | so the password is in git for the lab, not in a generated Secret you have to fetch |
| `grafana.grafana.ini.server.root_url` | `https://grafana.poc.local` | links Grafana renders point at the Gateway name (Part 2), not `localhost` |
| `grafana.sidecar.dashboards.searchNamespace` | `ALL` | the sidecar loads any ConfigMap labelled `grafana_dashboard=1` from **any** namespace — that is how Section B's Cilium dashboards (ConfigMaps in `kube-system`) appear without copying JSON around |
| `kubeControllerManager/kubeScheduler/kubeEtcd.enabled` | `false` | kind binds these to `127.0.0.1` on the control-plane nodes; the scrapes can never succeed and would sit as three permanent red targets |
| `kubeProxy.enabled` | `false` | poc1 has **no kube-proxy** (demo 03). Nothing to scrape |

**Install** — `--wait` so the command returns only when every pod is Ready; the release is named
`monitoring` so every object it creates is `monitoring-…`:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 \
  -n monitoring --create-namespace --kube-context kind-poc1 \
  -f demos/16-monitoring/values-kube-prometheus-stack.yaml --wait --timeout 10m
```

Recorded (2 min 13 s to Ready, 10 pods):

```
NAME: monitoring   STATUS: deployed   chart kube-prometheus-stack-90.1.1   app v0.93.1

alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2   Running   10.10.3.207   poc1-worker2
monitoring-grafana-b9bbf985-xlcn6                        3/3   Running   10.10.4.40    poc1-worker
monitoring-kube-prometheus-operator-57b74d8f5b-zw957     1/1   Running   10.10.3.227   poc1-worker2
monitoring-kube-state-metrics-7f584dc46d-dpxkb           1/1   Running   10.10.4.165   poc1-worker
monitoring-prometheus-node-exporter-…  ×5                1/1   Running   172.18.0.x    every node (hostNetwork)
prometheus-monitoring-kube-prometheus-prometheus-0       2/2   Running   10.10.4.70    poc1-worker
```

Ten CRDs from `monitoring.coreos.com` were installed with it (`kubectl get crd | grep -c monitoring.coreos.com`
→ 10) — `ServiceMonitor`, `PodMonitor`, `Prometheus`, `Alertmanager`, `PrometheusRule`, … These are
what Section B's Cilium values will create instances of.

**Is Prometheus actually scraping?** The Prometheus image has no `wget`/`curl`/shell, so
`kubectl exec` cannot ask it (the transcript shows that attempt failing — kept, because it is the
first thing everybody tries). Ask through the API server's service proxy instead, which needs
nothing in the pod and no port-forward:

```bash
kubectl --context kind-poc1 get --raw \
  "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/targets?state=active"
```

Recorded, grouped by scrape pool:

```
  serviceMonitor/monitoring/monitoring-grafana/0                       up  x1
  serviceMonitor/monitoring/monitoring-kube-prometheus-alertmanager/0  up  x1  (+/1 x1)
  serviceMonitor/monitoring/monitoring-kube-prometheus-apiserver/0     up  x3   ← the three control planes
  serviceMonitor/monitoring/monitoring-kube-prometheus-coredns/0       up  x2
  serviceMonitor/monitoring/monitoring-kube-prometheus-kubelet/0,1,2   up  x5 each  ← 5 nodes: kubelet, cAdvisor, probes
  serviceMonitor/monitoring/monitoring-kube-prometheus-operator/0      up  x1
  serviceMonitor/monitoring/monitoring-kube-prometheus-prometheus/0,1  up  x1 each
  serviceMonitor/monitoring/monitoring-kube-state-metrics/0            up  x1
  serviceMonitor/monitoring/monitoring-prometheus-node-exporter/0      up  x5
  total targets: 32  up: 32
```

No red targets — that is what the four `enabled: false` lines in the values bought.

**And the thing this demo is for is not there yet, by design.** Recorded immediately after:

```
  hubble_flows_processed_total series in Prometheus: 0
  No resources found in kube-system namespace.        ← kubectl get servicemonitor,podmonitor -n kube-system
  cilium ServiceMonitors in kube-system: 0
  dashboards: 25                                      ← the stack's own (node, kubelet, apiserver, …)
  hubble/cilium dashboards: []
```

Prometheus is up and scraping everything *it* knows about; it knows nothing about Cilium. Section B
is the single helm change that fixes that. Keep this "before" state in mind: it is the control.

## Part 2 — Grafana on the Gateway as `https://grafana.poc.local`

The demo 09 Gateway (`routes-gw`, `172.18.255.240`) terminates TLS with a wildcard `*.poc.local`
certificate from the cert-manager CA of demo 08, so a new hostname costs one `HTTPRoute`. The route
lives in `routes` with the Gateway; the backend `Service` is in `monitoring`, and Gateway API
refuses a cross-namespace backend unless the *target* namespace consents with a `ReferenceGrant`
(gotcha #32, same as the bank's `allow-routes-to-bank`). Both in
[`10-gateway.yaml`](10-gateway.yaml):

```bash
kubectl --context kind-poc1 apply -f demos/16-monitoring/10-gateway.yaml
kubectl --context kind-poc1 -n routes get httproute grafana \
  -o custom-columns='ROUTE:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,RESOLVED:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status'
```

```
ROUTE     HOSTS                 ACCEPTED   RESOLVED
grafana   [grafana.poc.local]   True       True        ← ResolvedRefs=True is the ReferenceGrant working
```

Proof from outside the cluster, before touching `/etc/hosts` (`--resolve` pins the name to the
Gateway address for this one call; the CA is the repo's `docs/root-ca.crt`):

```bash
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW https://grafana.poc.local/api/health
curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana https://grafana.poc.local/api/org
```

```
{"database": "ok", "version": "13.2.1", …}     -> http 200
{"id":1,"name":"Main Org.",…}                  ← the admin password from the values file works
```

## Part 3 — the hosts-file block for this demo (you run the `sudo` lines)

Same pattern as demos 09 and 15: a script that prints **its own delimited block** from live state
(the Gateway address and the route's hostnames, never hard-coded), so it can be added and removed
without touching the other demos' blocks. Scripts in this repo never write `/etc/hosts` themselves.

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc
demos/16-monitoring/hosts-entries.sh                                  # review first
sudo sh -c 'demos/16-monitoring/hosts-entries.sh >> /etc/hosts'      # you run this
grep -c 'grafana.poc.local' /etc/hosts                                # expect 1
dscacheutil -flushcache; sudo killall -HUP mDNSResponder              # drop the macOS resolver cache
open https://grafana.poc.local                                        # admin / poc-grafana
curl -s --cacert docs/root-ca.crt https://grafana.poc.local/api/health
```

What the script prints (recorded):

```
# ---- cilium-kind-poc monitoring (generated 2026-09-12T02:53Z by demos/16-monitoring/hosts-entries.sh) ----
172.18.255.240  grafana.poc.local
# ---- end cilium-kind-poc monitoring ----
```

Remove the block later, on its own, leaving the demo 09 and bank blocks untouched:

```bash
sudo sed -i '' '/---- cilium-kind-poc monitoring/,/---- end cilium-kind-poc monitoring/d' /etc/hosts
```

(`scripts/hosts-entries.sh` lists this name too now, since it reads every route on the Gateway;
use whichever block you prefer, not both.) The Mac still needs the demo 09 route to the kind
network — `sudo route -n add -net 172.18.0.0/16 192.168.64.2` — or `.240` is unreachable.

## Part 4 — what Section A leaves you with

- Prometheus at `http://monitoring-kube-prometheus-prometheus.monitoring:9090` in-cluster, reachable
  from the Mac through the API proxy URL above (or `kubectl port-forward`), scraping 32/32 targets.
- Grafana 13.2.1 at `https://grafana.poc.local`, 25 stock dashboards, Prometheus + Alertmanager
  datasources pre-wired.
- **Zero** Cilium or Hubble series, **zero** Cilium ServiceMonitors, **zero** Cilium dashboards. Every
  one of those numbers should change in Section B and nothing else should.

Uninstall, if ever needed (CRDs are deliberately left by helm; the second line removes them):

```bash
helm uninstall monitoring -n monitoring --kube-context kind-poc1
kubectl --context kind-poc1 get crd -o name | grep monitoring.coreos.com | xargs kubectl --context kind-poc1 delete
kubectl --context kind-poc1 delete -f demos/16-monitoring/10-gateway.yaml
```
