# Demo 16 — the junior guide: every command and why, as exercises

The README explains the results; this is the walk. Each step: **the command**, **why** (one line), **what to
expect**. Run from the repo root. Prerequisites: poc1 built per `docs/SETUP.md` Steps 0–9, the demo 09 Gateway.

## Exercise 1 — the stack (Section A)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update prometheus-community
helm install monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --create-namespace --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml --wait --timeout 10m
```

*Why:* Prometheus Operator + Prometheus + Grafana, pinned. The values file is the whole list of deviations, each with its reason — read it before running.
*Expect:* `STATUS: deployed`, 10 pods Running in `monitoring`.

```bash
kubectl --context kind-poc1 get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/targets?state=active" | python3 -c 'import json,sys; ts=json.load(sys.stdin)["data"]["activeTargets"]; print(len(ts), "targets,", sum(t["health"]=="up" for t in ts), "up")'
```

*Why:* the Prometheus image has no shell — ask through the API server's service proxy.
*Expect:* `32 targets, 32 up`. And zero Hubble series yet: that is the control.

## Exercise 2 — Grafana on the Gateway, and the hosts block (Parts 2–3)

```bash
kubectl --context kind-poc1 apply -f demos/16-monitoring/10-gateway.yaml
demos/16-monitoring/hosts-entries.sh
sudo sh -c 'demos/16-monitoring/hosts-entries.sh >> /etc/hosts'
dscacheutil -flushcache; sudo killall -HUP mDNSResponder
curl -s --cacert docs/root-ca.crt https://grafana.poc.local/api/health
```

*Why:* an HTTPRoute + ReferenceGrant on the demo 09 Gateway; the hosts script prints its own block from live state.
*Expect:* `ACCEPTED True RESOLVED True`, then `{"database": "ok", …}`.

## Exercise 3 — Cilium publishes (Section B, Part 5)

```bash
helm get values cilium -n kube-system --kube-context kind-poc1 -o yaml > .tmp/poc1-values-before-demo16.yaml
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 --reuse-values -f demos/16-monitoring/values-cilium-metrics.yaml
kubectl --context kind-poc1 -n kube-system rollout status ds/cilium --timeout=8m
kubectl --context kind-poc1 -n kube-system get servicemonitor
kubectl --context kind-poc1 get cm -A -l grafana_dashboard=1
```

*Why:* ServiceMonitors for agent, operator, Envoy, Hubble, relay, ClusterMesh; the six dashboard ConfigMaps. The agent gains a container port → every agent restarts → the Gateway is down for the rollout (measured 68 s).
*Expect:* 6 ServiceMonitors, 6 ConfigMaps; targets `52 up`; six Cilium/Hubble dashboards in Grafana.

## Exercise 4 — see the trap the dashboards hide (Parts 6–9)

```bash
kubectl --context kind-poc1 -n monitoring get cm hubble-network-overview-namespace -o jsonpath='{.data.*}' | python3 -c 'import json,sys,re; d=json.load(sys.stdin); print(sorted(set(re.findall(r"by \(([^)]*)\)", json.dumps(d)))))'
```

*Why:* the dashboards group by `source`, `destination`, `source_namespace`… labels the docs' default metric list does not produce. That is why `values-cilium-metrics.yaml` sets contexts (`app|workload-name|reserved-identity`, the namespace labels) and stamps a `cluster` label.
*Expect:* `['destination', 'destination, reason', 'source', …]` — and, on the dashboards, named peers across nodes and across the mesh.

```bash
kubectl --context kind-poc1 apply -f demos/16-monitoring/20-visibility-policies.yaml   # superseded by demo 19's cell; kept for the exercise
```

*Why:* DNS and per-workload HTTP metrics need the L7 proxy; a policy with an L7 rule puts a port on it.

## Exercise 5 — the reference values (Section C)

```bash
diff <(helm get values cilium -n kube-system --kube-context kind-poc1 -o yaml) demos/16-monitoring/values-cilium-metrics.yaml | head
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc1 --reuse-values -f demos/16-monitoring/values-cilium-metrics.yaml
kubectl --context kind-poc1 -n kube-system logs ds/cilium -c cilium-agent --since=2m | grep "failed reading dynamic" | tail -1
kubectl --context kind-poc1 -n kube-system rollout restart ds/cilium
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml
kubectl --context kind-poc1 get cm -A -l grafana_dashboard=1 -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,FOLDER:.metadata.annotations.grafana_folder'
```

*Why:* `ignoreAAAA` on dns (a context change → the dynamic reload refuses it, gotcha #59 → one restart), the dashboards to `monitoring` in folders, the sidecar told to honour `grafana_folder`.
*Expect:* the refusal line, a ~50 s Gateway outage, six ConfigMaps in `monitoring` with `Cilium` / `Hubble` folders, and Grafana's dashboard list grouped by folder.

## Exercise 6 — check it with a browser (Part 11)

See [`browser/README.md`](browser/README.md). *Expect:* no metric/histogram element anywhere in the Hubble UI; the histograms on the Hubble L7 dashboard.
