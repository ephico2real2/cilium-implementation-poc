# Demo 35 — the guide: exercises

Run from the repo root with poc1 up and demos 25 (cf2cnp behind the Gateway) and 26 (the helper scripts) in place.
Exercise 0 builds the platform (six namespaces); the rest read from it, apart from Exercise 3 which enforces.

## Exercise 0 — the platform, and who talks to whom before any policy

```bash
kubectl --context kind-poc1 apply -f demos/35-shop-platform/10-platform.yaml
sleep 20; demos/35-shop-platform/probe.sh
```

*Expect:* nine `200 OK` — the shopper through the gateway to four backends, the merchant's and the ratings' calls,
and the stranger straight at the catalog and at payments. Nothing is denied yet; the last three lines are the
ones that must change.

## Exercise 1 — observe first, across five namespaces at once

```bash
demos/35-shop-platform/audit-all.sh Enabled
kubectl --context kind-poc1 apply -f demos/35-shop-platform/20-default-deny-ingress.yaml
sleep 30; demos/35-shop-platform/audit-flows.sh /tmp/shop-audit.ndjson 400
```

*Expect:* seven endpoints in `PolicyAuditMode=Enabled`, one default-deny per namespace, and a summary of AUDIT
flows in which the catalog is called from four workloads in three namespaces plus the stranger. Nothing was
cut off: probe again and every line is still `200`.

## Exercise 2 — one request, six policies, descriptions that read like the architecture

```bash
QUERY="exclude=app.kubernetes.io%2Fname%3Dstranger" demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/shop-audit.ndjson /tmp/shop.yaml
python3 -c 'import yaml
for d in yaml.safe_load_all(open("/tmp/shop.yaml")):
    if d: print(d["metadata"]["namespace"], d["metadata"]["name"], "|", d["spec"]["description"])'
```

*Expect:* six policies, one per service, each in its own namespace, and for the catalog:
`Allow ingress to catalog in shop-core: from orders on TCP/80; from api-gateway in shop-edge on TCP/80; from merchant in shop-merchant on TCP/80; from reviews in shop-reviews on TCP/80`.
A peer in another namespace carries `io.kubernetes.pod.namespace` in its selector and says so in the sentence;
a peer in the same namespace does not (0.6.3). Generate once more without `exclude=` and the stranger is a rule
on two policies — cf2cnp reads flows, not verdicts (demo 32).

## Exercise 3 — enforce (writes: six policies, audit off)

```bash
kubectl --context kind-poc1 apply -f /tmp/shop.yaml
demos/35-shop-platform/audit-all.sh Disabled
demos/35-shop-platform/probe.sh
demos/35-shop-platform/verdicts.sh 200
```

*Expect:* six `200`s and three `rc=1`: the stranger at the catalog and at payments, and — the line to notice — the
**shopper** straight at the catalog. The shopper was only ever observed through the gateway, so the catalog's
policy names the gateway, not the shopper: the intent "clients go through the gateway" fell out of the
observation. `verdicts.sh` names the deciding policy on every forwarded line and none on the drops.

## Exercise 4 — the dashboard, both sides

`https://grafana.poc.local/d/hubble-policy-verdicts?var-cluster=poc1&var-namespace=shop-core` (the namespace as
the destination: who reaches the shared service) and the same page with `var-role=source_namespace&var-namespace=shop-clients`
(the namespace as the source: a client namespace's whole footprint).

*Expect:* on shop-core, forwarded rows for four callers from three namespaces and dropped rows for the stranger
and the direct shopper; on shop-clients as the source, the shopper forwarded into the gateway and the stranger
dropped at two services. The audited tile reads `none` once every endpoint enforces.

## Cleanup

`demos/35-shop-platform/cleanup.sh` — deletes the six namespaces.
