# Demo 27 — the guide: exercises

Run from the repo root; poc1 with demos 16, 24, 25 and 26 applied, the cf2cnp 0.5.0 release deployed
(demo 26 Part 14f). Demo 26's scripts take `NS=cf2cnp-lab27`. Set once:

```bash
GW=$(kubectl --context kind-poc1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
mkdir -p .tmp; export NS=cf2cnp-lab27; S26=demos/26-cf2cnp-policy-from-flows
```

## Exercise 0 — prove which release you are on

```bash
helm repo add cf2cnp-fork https://ephico2real2.github.io/cf2cnp; helm search repo cf2cnp-fork --versions
kubectl --context kind-poc1 -n hubble-observer get deploy hubble-observer-cf2cnp -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

*Expect:* chart 0.5.0 / app 0.5.0 and `ghcr.io/ephico2real2/cf2cnp:0.5.0`. Then POST `{}` to
`https://cf2cnp.poc.local/generate` — *Expect:* `400 … not a Hubble flow`, a 0.5.0 answer (0.3.1 generated a
policy with empty selectors).

## Exercise 1 — the lab, and the audit trap

```bash
kubectl --context kind-poc1 apply -f demos/27-cf2cnp-release/10-lab.yaml
kubectl --context kind-poc1 -n cf2cnp-lab27 wait --for=condition=Ready pod --all --timeout=180s
$S26/audit-mode.sh shop-frontend Enabled; $S26/audit-mode.sh shop-backend Enabled
kubectl --context kind-poc1 apply -f demos/27-cf2cnp-release/20-shop-default-deny-ingress.yaml
sleep 40; $S26/verify.sh 40s
```

*Expect:* `AUDIT` for all four relationships, both clients still answered. Now `kubectl rollout restart
deploy/shop-frontend`, wait, and run `verify.sh` again — *Expect:* `pos → shop-frontend DROPPED`: the new
endpoint has no audit flag (README Part 1c). Re-run `audit-mode.sh shop-frontend Enabled`; it names the
endpoint it flagged — read that line.

## Exercise 2 — collect by intent, generate once

```bash
hubble observe -P --kube-context kind-poc1 --verdict AUDIT --to-namespace cf2cnp-lab27 --not --from-pod cf2cnp-lab27/stranger --last 100 -o json > .tmp/flows.ndjson
wc -l .tmp/flows.ndjson
curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW -X POST https://cf2cnp.poc.local/generate --data-binary @.tmp/flows.ndjson -o .tmp/cnp.yaml
grep -n "^  name:\|component:" .tmp/cnp.yaml
```

*Expect:* two documents, `shop-backend` and `shop-frontend`, each with the component in the name, in the
labels and in the selector. Drop `--not --from-pod …/stranger` and repeat — *Expect:* the same two names,
now with a stranger rule in each: the filter was the intent.

## Exercise 3 — the collision you no longer get

```bash
curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW -X POST https://cf2cnp.poc.local/generate --data-binary @.tmp/flows.ndjson -H 'Accept: application/json' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["flows"], "flows →", d["policies"], "policies")'
```

*Expect:* `30 flows → 2 policies`. Read demo 26 Part 14e for what 0.3.1 did with the same intent: two objects
named `shop`, the second apply replacing the first, `pos` dropped 20 s later.

## Exercise 4 — apply, enforce, list by label

```bash
kubectl --context kind-poc1 apply -f .tmp/cnp.yaml
$S26/audit-mode.sh shop-frontend Disabled; $S26/audit-mode.sh shop-backend Disabled
sleep 45; $S26/verify.sh 45s
kubectl --context kind-poc1 -n cf2cnp-lab27 get cnp -l app.kubernetes.io/name=shop
kubectl --context kind-poc1 -n cf2cnp-lab27 get cnp -l app.kubernetes.io/component=backend
```

*Expect:* pos and the frontend `FORWARDED … by shop-frontend` / `by shop-backend`, stranger `DROPPED
POLICY_DENIED` at both; the label queries return the policies without knowing their names.

## Exercise 5 — the three doors, the same answer

```bash
SHOTS_DIR=.tmp/shots GW=$GW NODE_PATH=<dir with playwright> node $S26/ui-generate.js .tmp/flows.ndjson
SHOTS_DIR=.tmp/shots GW=$GW NODE_PATH=<dir with playwright> node $S26/grafana-generate.js cf2cnp-lab27
```

*Expect:* the page summarising 30 flows and producing 2 policies; the Grafana action on a dropped stranger
flow downloading `cf2cnp-lab27-shop-frontend.yaml` (or `-backend`, whichever drop is first in the table).

## Exercise 6 — where the components disappear

Open *Hubble / Policy Verdicts (Namespace)* for `cf2cnp-lab27` and Hubble UI on the namespace. *Expect:* the
metric's table and the service map both say `shop` twice — the destination context and the map group by
application name. `kubectl get cnp -l app.kubernetes.io/component=frontend` is where the component lives.

## Cleanup

```bash
demos/27-cf2cnp-release/cleanup.sh
```
