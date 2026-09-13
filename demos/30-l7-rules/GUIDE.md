# Demo 30 — the guide: exercises

Run from the repo root with poc1 up and demos 16 (the Hubble metrics), 25 (cf2cnp behind the Gateway) and 26
(the helper scripts) in place. Exercise 0 reads; the others write into the lab namespace only.

## Exercise 0 — what an L7 flow carries

```bash
kubectl --context kind-poc1 apply -f demos/30-l7-rules/10-lab.yaml -f demos/30-l7-rules/20-http-visibility.yaml
sleep 20; demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300
hubble observe -P --kube-context kind-poc1 --namespace cf2cnp-lab30 --protocol http --last 1 -o json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["flow"]["l7"], indent=1))'
```

*Expect:* one line per (caller → component, REQUEST/RESPONSE, method, path, status); the JSON shows
`l7.type`, `l7.http.method`, the **full URL** (`http://shop-backend.cf2cnp-lab30/api/orders?id=42`) and the
headers. Without the visibility policy there is no `l7` at all: the proxy is what reports it.

## Exercise 1 — the same flows, with and without `--l7`

```bash
demos/26-cf2cnp-policy-from-flows/generate.sh demos/30-l7-rules/policies/flows-http-intent.ndjson /tmp/shop-l4.yaml
QUERY=l7=true demos/26-cf2cnp-policy-from-flows/generate.sh demos/30-l7-rules/policies/flows-http-intent.ndjson /tmp/shop-l7.yaml
diff /tmp/shop-l4.yaml /tmp/shop-l7.yaml
```

*Expect:* only `rules.http` blocks are added — `method: GET` with `path: ^/api/orders(\?.*)?$` for the backend,
`^/(\?.*)?$` and `^/checkout(\?.*)?$` for the frontend. `/api/orders` seen with and without `?id=42` is one
rule. Same bytes otherwise (README Part 3).

## Exercise 2 — enforce and probe (writes: replaces the visibility policy)

```bash
kubectl --context kind-poc1 delete -f demos/30-l7-rules/20-http-visibility.yaml
kubectl --context kind-poc1 apply -f demos/30-l7-rules/30-shop-default-deny-ingress.yaml -f demos/30-l7-rules/policies/cnp-shop-l7.yaml
sleep 5; demos/30-l7-rules/calls.sh
demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 100 | grep -E "admin|promo"
hubble observe -P --kube-context kind-poc1 --namespace cf2cnp-lab30 --verdict DROPPED --last 4
```

*Expect:* `200 OK` for `/`, `/checkout`, `/checkout?promo=1` and `/api/orders?id=7`; `403 Forbidden` for
`/admin` from pos and from the frontend (the proxy's answer — nginx would have said 200); `rc=1` and no
status line for the stranger, whose SYN is `Policy denied DROPPED`. In Hubble the denied request is
`REQUEST … DROPPED` followed by `RESPONSE … 403 FORWARDED`.

## Exercise 3 — add a path without regenerating everything

Edit `policies/cnp-shop-l7.yaml`, add `- {method: GET, path: ^/admin$}` under the frontend's `rules.http`,
apply, and call `/admin` from pos again. Then try `POST /checkout` from pos
(`wget --post-data=x …`).

*Expect:* `/admin` is 200 now; the POST is 403 — the method is part of the rule, and the rule is the intent.

## Exercise 4 — the dashboards

`https://grafana.poc.local/d/hubble-policy-verdicts?var-cluster=poc1&var-namespace=cf2cnp-lab30` and the
Hubble L7 HTTP dashboard filtered to `cf2cnp-lab30` / `shop-frontend` (URLs in `evidence.json`).

*Expect:* the verdict table has `forwarded` and `dropped` rows with `match = l7/http` (the proxy decided) beside
the stranger's `dropped / none`; the L7 dashboard shows `200` and `403` series for the frontend.

## Cleanup

`demos/30-l7-rules/cleanup.sh` — deletes `cf2cnp-lab30`, nothing else.
