# Demo 34 — the guide: exercises

Run from the repo root with poc1 up, demos 25 (observer + Loki), 28/29 (the verdicts dashboard chart 0.2.0 with
its Loki row) and this demo's second observer release in place. Exercises 0–2 read; 3 uses a browser.

## Exercise 0 — two observers, two container labels

```bash
kubectl --context kind-poc1 -n hubble-observer get deploy -o custom-columns='DEPLOY:.metadata.name,CONTAINER:.spec.template.spec.containers[0].name,ARGS:.spec.template.spec.containers[0].args'
demos/34-verdict-to-policy/loki-verdicts.sh 15m
```

*Expect:* `hubble-observer` (`--verdict DROPPED`) and `hubble-observer-verdicts` (`--type policy-verdict`, no
`--verdict`), each with its own container name; in Loki two streams under `{namespace="hubble-observer"}`,
`container="hubble-observer"` and `container="hubble-observer-verdicts"`, and the "which policy allowed it" table.
With the chart's default container name both releases would land in one stream (README Part 1).

## Exercise 1 — one verdict, read in full

```bash
kubectl --context kind-poc1 -n hubble-observer logs deploy/hubble-observer-verdicts --tail=50 \
  | python3 -c 'import json,sys
for l in sys.stdin:
    f=json.loads(l)["flow"]
    for k in ("ingress_allowed_by","egress_allowed_by","ingress_denied_by","egress_denied_by"):
        if f.get(k): print(f["source"].get("pod_name") or f["source"]["labels"][0], "->", f["destination"].get("pod_name"), f["verdict"], k, [x.get("name") or x["labels"][0] for x in f[k]])'
```

*Expect:* one line per verdict with the deciding field and the policy's name — `shop-frontend`, `worker-batch`,
`allow-hubble-observer-verdicts-to-hubble-relay`; a `reserved:host → pod` line names no policy but carries
`derived-from=allow-localhost-ingress`: Cilium's implicit allow for the node, not a CRD.

## Exercise 2 — a question the metric cannot answer

On the Policy Verdicts dashboard the metric says `forwarded` for `pos → shop`. Which rule? Ask the stream:

```bash
kubectl --context kind-poc1 -n monitoring port-forward svc/loki 23100:3100 >/dev/null 2>&1 & sleep 2
curl -s -G http://127.0.0.1:23100/loki/api/v1/query --data-urlencode 'query=sum by (allowed_by) (count_over_time({container="hubble-observer-verdicts"} | json src="flow.source.pod_name", allowed_by="flow.ingress_allowed_by[0].name" | src="pos" | allowed_by != "" [15m]))' | python3 -m json.tool | grep -A1 allowed_by
kill %1
```

*Expect:* `shop-frontend` (demo 27's generated policy, evolved in demo 32) — and nothing else. Change `src` to
`stranger` and the result is empty: its verdicts are `DROPPED` with no policy named (a default-deny).

## Exercise 3 — the Loki row's action (the browser)

Open `https://grafana.poc.local/d/hubble-policy-verdicts?var-cluster=poc1&var-namespace=cf2cnp-lab27`, scroll to
*Dropped flows → policy (Loki, via cf2cnp)*, click a Flow UUID → *Generate CiliumNetworkPolicy from Flow* →
Confirm → click the UUID again → *Download CiliumNetworkPolicy*.

*Expect:* the same two actions demo 26 Part 12 wired on the observer dashboard, on the verdict dashboard's own
row: one page from the verdict to the policy. Scripted: `DASH_URL=… node demos/26-cf2cnp-policy-from-flows/grafana-generate.js cf2cnp-lab27`
(README Part 3).

## Cleanup

`demos/34-verdict-to-policy/cleanup.sh` — uninstalls the second release only.
