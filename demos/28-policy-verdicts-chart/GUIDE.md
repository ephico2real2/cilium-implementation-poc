# Demo 28 — the guide: exercises

Run from the repo root. The exercises use the released charts, so they need only Helm, `kubectl` on poc1
(demos 16 and 25 applied) and, for the last one, a browser.

## Exercise 0 — install the dashboard on its own, both ways, without applying

```bash
helm repo add hubble-policy-verdicts https://ephico2real2.github.io/hubble-policy-verdicts && helm repo update hubble-policy-verdicts
helm template pv hubble-policy-verdicts/hubble-policy-verdicts -n monitoring | grep -E "^kind|^  name|grafana_"
helm template pv hubble-policy-verdicts/hubble-policy-verdicts --set sidecar.enabled=false --set grafanaOperator.enabled=true | grep -E "^kind|instanceSelector" -A2
```

*Expect:* a ConfigMap named `hubble-policy-verdicts` with `grafana_dashboard: "1"` and `grafana_folder: Hubble`;
then a `GrafanaDashboard` with the operator's instance selector. Same JSON in both.

## Exercise 1 — reproduce the 0.1.0 bug, then see 0.1.1 refuse it

```bash
mkdir -p .tmp/parent/charts && helm pull hubble-policy-verdicts/hubble-policy-verdicts --version 0.1.0 --untar -d .tmp/parent/charts
printf 'apiVersion: v2\nname: parent\nversion: 0.0.1\ndependencies:\n  - name: hubble-policy-verdicts\n    alias: policyVerdictsDashboard\n    version: "*"\n    condition: policyVerdictsDashboard.enabled\n' > .tmp/parent/Chart.yaml
echo "policyVerdictsDashboard: {enabled: true}" > .tmp/parent/values.yaml
helm template t .tmp/parent -n monitoring | grep "^  name:"
kubectl --context kind-poc1 apply --dry-run=server -f <(helm template t .tmp/parent -n monitoring)
```

*Expect:* `name: policyVerdictsDashboard` and the API server's `Invalid value … lowercase RFC 1123 subdomain`.
Repeat with `--version 0.1.1`: *Expect:* `name: hubble-policy-verdicts`, dry run `created`. That is the
repository's CI job, by hand.

## Exercise 2 — as the observer chart's dependency

```bash
git clone -q --branch develop https://github.com/ephico2real2/hubble-observer .tmp/ho && (cd .tmp/ho/helm/hubble-observer && helm dependency build >/dev/null && ls charts)
helm template t .tmp/ho/helm/hubble-observer -n hubble-observer | grep -c "kind: ConfigMap"
helm template t .tmp/ho/helm/hubble-observer -n hubble-observer --set policyVerdictsDashboard.enabled=true | grep -B2 -A3 "name: hubble-policy-verdicts" | head -8
```

*Expect:* `cf2cnp-0.5.1.tgz hubble-policy-verdicts-0.1.1.tgz`; no ConfigMap with the value off; the ConfigMap
in the release namespace with it on — set `policyVerdictsDashboard.sidecar.namespace=monitoring` to see it
move.

## Exercise 3 — the dashboard is the one Grafana shows

```bash
kubectl --context kind-poc1 -n monitoring get cm hubble-policy-verdicts -o jsonpath='{.metadata.labels}{"\n"}'
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana "https://grafana.poc.local/api/search?query=Policy%20Verdicts" | python3 -m json.tool | grep -E '"uid"|"folderTitle"'
```

*Expect:* labels naming the chart and the `hubble-observer` release instance; one dashboard, uid
`hubble-policy-verdicts`, folder Hubble. Delete the ConfigMap and re-run `chart-from-fork.sh develop` — Helm
puts it back; that is what "owned by a release" means.

## Exercise 4 — 0.5.1's summary

Open `https://cf2cnp.poc.local/`, paste `demos/27-cf2cnp-release/policies/flows-audit.ndjson`. *Expect:* the
summary line reading `shop/frontend → shop/backend:80` and `pos → shop/frontend:80` — the same identity the
policy names are built from.

## Exercise 5 — read the upstream conversation

[onzack/hubble-observer#12](https://github.com/onzack/hubble-observer/issues/12) and
[PR #13](https://github.com/onzack/hubble-observer/pull/13). If the author prefers the JSON inside their
`dashboard/` directory, the chart's `dashboards/hubble-policy-verdicts.json` is the file to contribute.
