# Demo 33 — the guide: exercises

Run from the repo root with poc1 up and the hardened observer release in place (demo 33's end state). Every
exercise reads; Exercise 3 changes one Helm value for one revision and puts it back.

## Exercise 0 — who can reach cf2cnp now

```bash
kubectl --context kind-poc1 -n hubble-observer get cnp -o custom-columns='NAME:.metadata.name,INGRESS-FROM:.spec.ingress[0].fromEntities'
kubectl --context kind-poc1 -n cf2cnp-lab27 exec pos -- sh -c 'wget -qO- --timeout=3 --post-data="{}" http://hubble-observer-cf2cnp.hubble-observer/generate; echo rc=$?'
curl -s -o /dev/null -w 'gateway: HTTP %{http_code}\n' --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:172.18.255.240 https://cf2cnp.poc.local/health
hubble observe -P --kube-context kind-poc1 --to-pod hubble-observer/hubble-observer-cf2cnp --port 8080 --type policy-verdict --last 10
```

*Expect:* two policies for the pod, both `[ingress host]`; the lab pod gets no answer (`rc=1`), the Gateway
answers `200`; the verdicts name `reserved:host` (the kubelet's probes) and `reserved:ingress` (the Gateway) as
`FORWARDED`, the lab pod as `DROPPED`.

## Exercise 1 — policies add, they never narrow (the Part 2a measurement)

```bash
helm --kube-context kind-poc1 -n hubble-observer get values hubble-observer -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciliumNetworkPolicy"]["cf2cnp"])'
```

Set the parent's `ingressFromEntities` back to `[cluster, world]` in a copy of the values file, redeploy, and run
Exercise 0 again; then put it back.

*Expect:* with the parent chart's policy at `[cluster, world]` the lab pod is `FORWARDED` again — by
`allow-hubble-observer-cf2cnp-ingress` — although the subchart's `[ingress, host]` policy is still there. A
policy can only add allows; the widest one wins. Gotcha #88.

## Exercise 2 — the Origin allow-list

```bash
C="curl -s -o /dev/null -D - --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:172.18.255.240 -X POST https://cf2cnp.poc.local/generate -H 'Content-Type: application/json' -d {}"
$C -H 'Origin: https://evil.example'      | grep -i 'access-control-allow-origin\|vary' || echo "(no CORS headers)"
$C -H 'Origin: https://grafana.poc.local' | grep -i 'access-control-allow-origin\|vary'
```

*Expect:* nothing for the foreign origin (a browser there cannot read the answer); the Grafana origin echoed
with `vary: Origin`. curl itself always gets the answer — CORS is a browser rule, the policy in Exercise 0 is the
network one.

## Exercise 3 — the token, for one revision (writes: one Helm revision, then back)

```bash
helm upgrade --install hubble-observer .tmp/hubble-observer-fork/helm/hubble-observer -n hubble-observer --kube-context kind-poc1 \
  -f demos/25-hubble-observer-loki/values-hubble-observer.yaml --set ciliumNetworkPolicy.enabled=true --set cf2cnp.auth.token=try-me --wait
C="curl -s -o /dev/null -w 'HTTP %{http_code}\n' --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:172.18.255.240"
$C -X POST https://cf2cnp.poc.local/generate --data-binary @demos/32-operator-loop/policies/flows-frontend.ndjson
$C -X POST https://cf2cnp.poc.local/generate --data-binary @demos/32-operator-loop/policies/flows-frontend.ndjson -H 'Authorization: Bearer try-me'
$C https://cf2cnp.poc.local/health
demos/25-hubble-observer-loki/chart-from-fork.sh develop a00dd7e     # back: no token
```

*Expect:* `401` (with `WWW-Authenticate: Bearer realm="cf2cnp"`), `200`, `200`. Open the page: the *Access token*
field, kept in the tab's sessionStorage. Then try the dashboard action while the token is on — `401`: the action's
request has no header slot for a secret, which is why the shared instance runs without a token (README Part 3).

## Exercise 4 — the dashboard action, under the controls

```bash
GW=172.18.255.240 NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/grafana-generate.js cf2cnp-lab27
```

*Expect:* the action's `POST https://cf2cnp.poc.local/generate` answered `200` with a `download_url` — through the
Gateway (`reserved:ingress`), from the allowed origin.

## Cleanup

`demos/33-hardening/cleanup.sh` — prints the state and removes nothing: the hardened configuration is the one
the values file commits.
