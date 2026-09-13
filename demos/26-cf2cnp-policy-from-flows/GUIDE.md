# Demo 26 — the guide: from one flow to an enforced policy, step by step

Run from the repo root; poc1 with demos 16, 24 and 25 applied and the CLI configured once
(`scripts/hubble-tls.sh --configure kind-poc1 kind-poc2`). Each exercise: the command, why, what to expect.
`demos/26-cf2cnp-policy-from-flows/verify.sh [since]` after each shows the verdicts;
`policy-metric.sh` shows the same as counts. Set `GW` once for the browser scripts:

```bash
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
mkdir -p .tmp     # scratch files below go here; the directory is git-ignored and does not exist in a fresh clone
```

## Exercise 0 — the lab, and a baseline

```bash
kubectl --context kind-poc1 apply -f demos/26-cf2cnp-policy-from-flows/10-lab.yaml
kubectl --context kind-poc1 -n cf2cnp-lab wait --for=condition=Ready pod --all --timeout=120s
sleep 30; demos/26-cf2cnp-policy-from-flows/verify.sh 30s
```

*Expect:* `pos → shop:80`, `stranger → shop:80`, `pos → reserved:world:443` and the CoreDNS lookups, all
`FORWARDED`, no policy column. Note which node each pod landed on (`get pods -o wide`).

## Exercise 1 — get one flow, four ways

```bash
G=demos/26-cf2cnp-policy-from-flows/get-flow.sh
$G cli --from-pod cf2cnp-lab/pos --to-pod cf2cnp-lab/shop | python3 -m json.tool | head -40
$G export poc1-worker2 '"pos".*cf2cnp-lab' | python3 -c 'import json,sys; f=json.load(sys.stdin)["flow"]; print(f["traffic_direction"], f["verdict"], f["node_name"])'
```

*Expect:* the JSON envelope (`flow`, `node_name`, `time`); inside `flow`, the five fields cf2cnp reads
(README Part 2). Both report `EGRESS` — with no policy on `shop`, nobody reports INGRESS. Now try what the
CLI refuses:

```bash
hubble observe -P --kube-context kind-poc1 --namespace cf2cnp-lab --from-pod cf2cnp-lab/pos --last 5
```

*Expect:* an error — `--from-pod` already names the namespace. (The Loki and observer sources only hold
DROPPED flows until Exercise 5; they come back in Exercise 6.)

## Exercise 2 — the egress policy, and why it says CIDR

```bash
$G cli --from-pod cf2cnp-lab/pos --to-port 443 > .tmp/flow-world.json
demos/26-cf2cnp-policy-from-flows/generate.sh .tmp/flow-world.json
```

*Expect:* an egress policy for `pos` with `toCIDR: <the resolved IP>/32` and cf2cnp's comment offering
`toEntities: [world]`; no `toFQDNs`, because the flow has no `destination_names`. Apply demo 19's DNS
visibility rule to a copy of `pos` and repeat to see the FQDN form appear.

## Exercise 3 — the wrong default-deny, then the right one

```bash
kubectl --context kind-poc1 apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: shop-default-deny-ingress, namespace: cf2cnp-lab}
spec:
  endpointSelector: {matchLabels: {app: shop}}
  ingress: []
EOF
sleep 3; kubectl --context kind-poc1 -n cf2cnp-lab get cnp shop-default-deny-ingress -o jsonpath='{.status.conditions[0].status}: {.status.conditions[0].message}{"\n"}'
```

*Expect:* `False: rule must have at least one of Ingress, IngressDeny, Egress, EgressDeny` — the object
exists, protects nothing (gotcha #80). Then audit mode and the real one:

```bash
demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Enabled
kubectl --context kind-poc1 apply -f demos/26-cf2cnp-policy-from-flows/20-shop-default-deny-ingress.yaml
sleep 45; demos/26-cf2cnp-policy-from-flows/verify.sh 45s
kubectl --context kind-poc1 -n cf2cnp-lab exec stranger -- wget -qO- -S --timeout=3 http://shop.cf2cnp-lab/ 2>&1 | head -1
```

*Expect:* `AUDIT` lines for both clients (these are `INGRESS`, reported by shop's node) **and** `HTTP/1.1
200 OK` for `stranger` — evaluated, not enforced. `policy-metric.sh cf2cnp-lab` shows `action=audit
match=none` rising for both.

## Exercise 4 — generate through the API, read the names

```bash
P=demos/26-cf2cnp-policy-from-flows/policies
$G cli --verdict AUDIT --from-pod cf2cnp-lab/pos      --to-pod cf2cnp-lab/shop > $P/flow-pos-to-shop.json
$G cli --verdict AUDIT --from-pod cf2cnp-lab/stranger --to-pod cf2cnp-lab/shop > $P/flow-stranger-to-shop.json
demos/26-cf2cnp-policy-from-flows/generate.sh $P/flow-pos-to-shop.json      $P/cnp-pos-to-shop.yaml
demos/26-cf2cnp-policy-from-flows/generate.sh $P/flow-stranger-to-shop.json $P/cnp-stranger-to-shop.yaml
grep -h '^  name:' $P/cnp-pos-to-shop.yaml $P/cnp-stranger-to-shop.yaml
```

*Expect:* two ingress policies selecting `app.kubernetes.io/name: shop`, one `fromEndpoints` each — **both
named `shop`** (gotcha #81). Decide from the intent, not the log: apply only the `pos` one.

## Exercise 5 — apply under audit, then enforce, then read the verdicts

```bash
kubectl --context kind-poc1 apply -f $P/cnp-pos-to-shop.yaml
sleep 40; demos/26-cf2cnp-policy-from-flows/verify.sh 40s
demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Disabled
sleep 45; demos/26-cf2cnp-policy-from-flows/verify.sh 45s; demos/26-cf2cnp-policy-from-flows/policy-metric.sh cf2cnp-lab
```

*Expect:* first `pos → shop FORWARDED by shop` with `stranger` still `AUDIT`; after the flag,
`stranger → shop DROPPED POLICY_DENIED` and `stranger`'s `wget` timing out, `pos` still 200. In the
metric: `forwarded l3-l4` for pos, `dropped none` for stranger, `audit` frozen at its last count.

## Exercise 6 — the same flow from the store, the log and the file

```bash
$G loki '{namespace="hubble-observer",container="hubble-observer"} | json | flow_source_pod_name="stranger" | flow_destination_namespace="cf2cnp-lab" | flow_verdict="DROPPED"' 30 > .tmp/f-loki.json
$G observer '"stranger".*cf2cnp-lab' > .tmp/f-obs.json
$G export poc1-worker2 'DROPPED.*stranger' > .tmp/f-exp.json
for f in .tmp/f-loki.json .tmp/f-obs.json .tmp/f-exp.json; do demos/26-cf2cnp-policy-from-flows/generate.sh $f | grep -v '^#' | md5; done
```

*Expect:* three identical checksums, and identical to Exercise 4's `stranger` file (the transcript's
`31c4209a…`). The source decides *how far back* you can look, not *what* you get. Change the Loki selector
to `flow_verdict="FORWARDED"` — nothing: the observer exports drops only (demo 25 `verdictFilter`).

## Exercise 7 — the Web UI and the Grafana action

```bash
GW=$GW NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/ui-generate.js $P/flow-stranger-to-shop.json
GW=$GW NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/grafana-generate.js cf2cnp-lab
```

*Expect:* the UI script printing the same YAML and writing `ui-1..3.png`; the Grafana script printing the
first UUID, `menu offers: Generate … | Download … | Open …`, `confirmed the action`, the `POST /generate`
with `x-grafana-action: 1` and the `200 {"download_url": …}` answer. Then, by hand, within ten minutes:

```bash
curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW https://cf2cnp.poc.local/download/<that uuid>
```

*Expect:* the policy; after ten minutes, `404` (the cache is keyed by UUID and expires). Do the same in a
browser: dashboard → Flow UUID → *Generate* → *Confirm* → the cell again → *Download*.

## Exercise 8 — read it on every dashboard

Open, with the time range on the last 45 minutes:

- `https://hubble.poc.local/?namespace=cf2cnp-lab` — *Expect:* `dropped` rows for `stranger`, `forwarded` for `pos`.
- Hubble / Network Overview (Namespace), cluster `poc1`, namespaces `cf2cnp-lab` — *Expect:* three verdict
  series (AUDIT, DROPPED, FORWARDED) and `stranger: POLICY_DENIED` / `shop: POLICY_DENIED` in the drops row.
- Hubble Metrics and Monitoring → *Network Policy* — *Expect:* `stranger` in *Top 10 Source Pods with Denied Packets*.
- Cilium Flows - Hubble Observer, destination namespace `cf2cnp-lab` — *Expect:* the drop count, `POLICY_DENIED`,
  and *Flows per Denying Policy* **empty** (gotcha #82: a default-deny names no policy).
- Hubble / Policy Verdicts (Namespace) — *Expect:* the three totals, *Workloads still audited* at 0 now, the
  audit line ending where the dropped line begins, and `match=none` on the stranger rows of the table.

## Exercise 9 — reverse it, the safe way

```bash
demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Enabled
sleep 30; demos/26-cf2cnp-policy-from-flows/verify.sh 30s
```

*Expect:* `stranger` back to `AUDIT` and answered again, `pos` still `FORWARDED by shop` — audit mode is
the reversible switch, the policy objects untouched. `audit-mode.sh shop Disabled` re-enforces. Delete the
`shop` pod and run `audit-mode.sh` again: the flag did not survive the endpoint (README Part 4).

## Exercise 10 — extend the dashboard

Edit [`30-policy-verdicts-dashboard.json`](30-policy-verdicts-dashboard.json) — add a stat for
`sum(increase(hubble_policy_verdicts_total{match="l7"}[$__range]))` — and run
`demos/26-cf2cnp-policy-from-flows/dashboard.sh`. *Expect:* the sidecar log line placing the ConfigMap in
`/tmp/dashboards/Hubble` and the panel live within a minute; with demo 19's L7 rules on the bank, that stat
is non-zero for namespace `bank`.

## Cleanup

```bash
demos/26-cf2cnp-policy-from-flows/cleanup.sh
```
