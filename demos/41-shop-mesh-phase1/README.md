# Demo 41 — the shop platform on the mesh, phase 1

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This is phase 1 of
[enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)
revision 4, tracking issue #42, §4 row 1. Demo 40 laid the doors; this
phase puts demo 35's platform behind them, twice, with global services
that prefer home. Nothing from phases 2–5 (no database, no egress
gateway, no HPA, no failure scenarios). Builds happened in demo 40;
this phase measures (gotcha #118: no docker on the VM while measuring).

## Summary context — the enterprise case

One public URL, a door per cluster, the same platform twice. An
external customer keeps calling `https://api.shop.poc.local`; what
happens behind that address is the mesh's business. Each cluster also
has its own door (`api.poc1.shop.poc.local`,
`api.poc2.shop.poc.local`) so an operator can watch one side without
going through the VIP.

The platform is byte-identical in both clusters: the same namespaces,
the same Deployments, every stateless Service annotated
`service.cilium.io/global: "true"` and
`service.cilium.io/affinity: local`. The only per-cluster value is
`CLUSTER` for the Go backend, and that lives in ConfigMap
`shop-cluster` written by apply-both.sh (`data.name=poc1` / `poc2`),
not in the manifest.

`X-Served-By` is set by the Gateway (Cilium's front-door object,
listeners in the node's shared Envoy) in the cluster the request
entered. It names the door, not whether the backend behind
`api-gateway` was local or remote. That second question is Hubble's
`destination.cluster_name`, measured in phase 5. The path a request
takes is in the [RECAP Architecture](RECAP.md#architecture).

A fresh lab enforces from the first apply: apply-both.sh lands the
reviewed policy set — demo 35's default-deny per namespace and this
cluster's seven cf2cnp policies under `policies/<cluster>/` — before
the probes. observe-and-enforce.sh is how that set is regenerated from
fresh flows.

## Files

| File | What |
|---|---|
| [`10-platform.yaml`](10-platform.yaml) | demo 35's platform, cluster-neutral and global, plus `backend` (`shopapi:local`) |
| [`20-routes-poc1.yaml`](20-routes-poc1.yaml) / [`20-routes-poc2.yaml`](20-routes-poc2.yaml) | HTTPRoute on both doors, `X-Served-By`, `:80` → 301 |
| [`20-default-deny-ingress.yaml`](20-default-deny-ingress.yaml) | demo 35's default-deny, applied to both clusters |
| [`apply-both.sh`](apply-both.sh) | ConfigMap, platform, routes, saved policies, Mac probes, global-service measurement, check |
| [`probe.sh`](probe.sh) | both `shopctl`s; needs `/etc/hosts` |
| [`audit-both.sh`](audit-both.sh) / [`flows-both.sh`](flows-both.sh) / [`generate-both.sh`](generate-both.sh) / [`verdicts-both.sh`](verdicts-both.sh) | demo 35's workflow, generalised |
| [`observe-and-enforce.sh`](observe-and-enforce.sh) | the R10 sequence as one command |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | routes, policies, platform; leaves demo 40's doors |
| [`policies/poc1/`](policies/poc1/) / [`policies/poc2/`](policies/poc2/) | generated CNPs and the AUDIT flows they came from |
| [`GUIDE.md`](GUIDE.md) | hosts-block prerequisite and five read-only exercises |
| clients | still in [`demos/40-shop-mesh-phase0/client/`](../40-shop-mesh-phase0/client/) (built in phase 0) |

## Run it

From the repo root. Both clusters up, demo 40 applied
(`shopapi:local` on the nodes, both `shopctl`s built). Do not rebuild.

```bash
demos/41-shop-mesh-phase1/apply-both.sh
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
demos/41-shop-mesh-phase1/observe-and-enforce.sh
demos/41-shop-mesh-phase1/probe.sh
demos/41-shop-mesh-phase1/check.sh
```

Every command goes through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt). apply-both.sh
truncates that file and records its own run; observe-and-enforce.sh
appends.

## What was recorded

The last apply (`2026-09-18T14:32:06Z`, transcript lines 1–247) and
the last check (`2026-09-18T14:32:18Z`). Enforcement
(`verify_enforcement`) was recorded immediately after, at
`2026-09-18T14:32:51Z`.

### 1. Apply the platform

apply-both.sh writes ConfigMap `shop-cluster` per context, applies the
byte-identical platform, and waits for every Deployment Available
(≤ 180 s). Then it records `cilium-dbg service list` for catalog.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/output/shop-cluster-poc1.yaml
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/10-platform.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/output/shop-cluster-poc2.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/10-platform.yaml
```

Recorded (last apply):

```text
namespace/shop-core unchanged
configmap/shop-cluster unchanged
namespace/shop-edge unchanged
namespace/shop-payments unchanged
deployment.apps/api-gateway unchanged
service/api-gateway unchanged
deployment.apps/catalog unchanged
service/catalog unchanged
deployment.apps/backend unchanged
service/backend unchanged
deployment.apps/api-gateway condition met
deployment.apps/catalog condition met
deployment.apps/backend condition met
pod/shopper condition met
```

Recorded (last apply):

```text
-- kind-poc1 catalog ClusterIP=10.11.58.134
-- annotations global=true affinity=local
-- cilium-dbg service list
172   10.11.58.134:80/TCP       ClusterIP      1 => 10.10.0.46:80/TCP (active)
 backend 10.10.0.46 state=active preferred=True
-- kind-poc2 catalog ClusterIP=10.21.123.1
-- annotations global=true affinity=local
95   10.21.123.1:80/TCP       ClusterIP      1 => 10.20.0.135:80/TCP (active)
 backend 10.20.0.135 state=active preferred=True
```

`cilium-dbg service list` prints the selected set (one backend).
statedb holds both copies; the BPF map selects the local one
(`known=2 (clustermesh=1) selected=1 local` — see *Checks*). Cilium
`pkg/clustermesh/selectbackends.go` sets
`useRemote = localActiveBackends == 0`. Under enforced policy a
shopper wget of catalog times out: shopper is not a catalog caller.

Recorded (last apply):

```text
wget: download timed out
command terminated with exit code 1
```

### 2. Attach the HTTPRoutes

Two files a junior can read (demo 40's choice). apply-both.sh waits
for both HTTPRoutes Accepted+ResolvedRefs on both doors, prints the
four hosts names, and probes the three doors from the Mac.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/20-routes-poc1.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/20-routes-poc2.yaml
```

Recorded (last apply):

```text
httproute.gateway.networking.k8s.io/shop-api configured
httproute.gateway.networking.k8s.io/shop-redirect configured
kind-poc1 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-poc1 httproute/shop-redirect: all parents Accepted+ResolvedRefs
kind-poc2 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-poc2 httproute/shop-redirect: all parents Accepted+ResolvedRefs
```

Recorded (last apply):

```text
# ---- cilium-kind-poc demo40 (generated 2026-09-18T14:32Z by demos/40-shop-mesh-phase0/hosts-entries.sh) ----
172.18.255.16  api.shop.poc.local
172.18.255.242  api.poc1.shop.poc.local
172.18.255.177  api.poc2.shop.poc.local
# db-service.poc.local  — phase 2 (db-gw does not exist yet)
# ---- end cilium-kind-poc demo40 ----
```

Recorded (last apply):

```text
HTTP/2 200
server: envoy
x-served-by: poc1
x-served-by: poc2
```

The VIP's header followed the announcer (poc1). Hitting `.177`
produced `poc2` even though the VIP is announced by poc1 — each door
is its own Gateway. HTTP/2 prints the header lowercase.

### 3. Apply the saved policies

The reviewed set — default-deny per namespace plus the seven cf2cnp
policies — is applied before the probes so a rebuilt cluster is
enforcing. The last apply found the objects already present; *Checks*
measures the inventory.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/20-default-deny-ingress.yaml
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/policies/poc1/cnp-shop-intent.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/20-default-deny-ingress.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/policies/poc2/cnp-shop-intent.yaml
```

Recorded (last check):

```text
  PASS   poc1 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc1 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   poc2 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc2 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
```

### 4. Observe the flows

observe-and-enforce.sh turns audit on, applies default-deny, sends
traffic through the three doors and the in-mesh shopper, then captures
Hubble. `flows-both.sh` passes `--cluster <name>` and keeps lines
whose `node_name` starts with that cluster. The last apply did not
re-run the capture; the committed files are the record
([docs/REVIEW_DEMO41.md](../../docs/REVIEW_DEMO41.md)): poc1 151
lines, all `node_name` `poc1/…`; poc2 140 lines, all `poc2/…`.

```bash
demos/41-shop-mesh-phase1/audit-both.sh Enabled
demos/41-shop-mesh-phase1/flows-both.sh 400
```

### 5. Generate the policies

One `/generate` per cluster, POSTed to `https://cf2cnp.poc.local/generate`
on poc1 (demo 26's path). The generated selectors have no cluster
label: Cilium 1.19+ matches the local cluster only. The flows were
same-cluster, so cf2cnp omitted it. api-gateway's policy also has
`fromEntities: [ingress]` — the Gateway's identity.

```bash
demos/41-shop-mesh-phase1/generate-both.sh
```

Seven policies each, `app.kubernetes.io/managed-by: cf2cnp`, stranger
excluded. Descriptions (same on both clusters) are in the
[RECAP Reference](RECAP.md#reference).

### 6. Enforce the policies

Audit mode Disabled on every shop endpoint (gotcha #84: the flag is
endpoint-local).

```bash
demos/41-shop-mesh-phase1/audit-both.sh Disabled
```

Recorded (last check):

```text
  PASS   poc1 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   poc2 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   VIP /healthz still 200 after policies                                  http_code=200 X-Served-By=poc1                       probe /healthz is 200 with the header
  PASS   X-Served-By never absent on /healthz                                   X-Served-By=poc1                                     the Gateway filter SET the header
```

### 7. Verify enforcement

`verify_enforcement` (inside observe-and-enforce.sh) measures the
drop, not assumes it.

```bash
demos/41-shop-mesh-phase1/observe-and-enforce.sh
```

Recorded (`2026-09-18T14:32:51Z`):

```text
stranger -> catalog: expected failure rc=1 output=wget: download timed out
command terminated with exit code 1
catalog-5799bdf56f-qsd4p
-- DROPPED stranger->catalog (from hubble observe --verdict DROPPED):
  DROPPED stranger -> catalog-5799bdf56f-qbv7m shop-core DROPPED
-- FORWARDED api-gateway->catalog (from hubble observe --verdict FORWARDED):
  FORWARDED api-gateway-c448767bb-sljk4 -> catalog-5799bdf56f-qsd4p FORWARDED
kind-poc1: DROPPED stranger->catalog and FORWARDED api-gateway->catalog observed
kind-poc2: DROPPED stranger->catalog and FORWARDED api-gateway->catalog observed
```

### 8. Run the checks

apply-both.sh ends on check.sh. The final table from the same run
(`2026-09-18T14:32:17Z`). HTTP/2 prints `x-served-by` lowercase;
`header_of` strips CR and matches the name case-insensitively.

```bash
demos/41-shop-mesh-phase1/check.sh
```

Recorded (last apply):

```text
CLUSTER  DEPLOYMENTS    HTTPROUTES             VIP                          POC1_DOOR                    POC2_DOOR
poc1     7/7            2/2 accepted, 2/2 resolved 200 X-Served-By=poc1         200 X-Served-By=poc1         200 X-Served-By=poc2
poc2     7/7            2/2 accepted, 2/2 resolved 200 X-Served-By=poc1         200 X-Served-By=poc1         200 X-Served-By=poc2
```

## Checks

`check.sh` at `2026-09-18T14:32:18Z`: 33 PASS, 0 FAIL, 0 WARN.

Recorded (last check):

```text
== demo 41 — the shop platform on the mesh, phase 1 (the platform behind the doors)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   poc1/shop-edge/api-gateway Available                                   1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-core/catalog Available                                       1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-core/orders Available                                        1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-core/backend Available                                       1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-payments/payment-gateway Available                           1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-merchant/merchant Available                                  1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-reviews/reviews Available                                    1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-edge/api-gateway Available                                   1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-core/catalog Available                                       1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-core/orders Available                                        1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-core/backend Available                                       1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-payments/payment-gateway Available                           1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-merchant/merchant Available                                  1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc2/shop-reviews/reviews Available                                    1/1                                                  availableReplicas == spec.replicas ≥ 1
  PASS   poc1/shop-api Accepted on both doors                                   accepted=2/2 resolved=2/2                            every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)
  PASS   poc1/shop-redirect Accepted on both doors                              accepted=2/2 resolved=2/2                            every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)
  PASS   poc2/shop-api Accepted on both doors                                   accepted=2/2 resolved=2/2                            every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)
  PASS   poc2/shop-redirect Accepted on both doors                              accepted=2/2 resolved=2/2                            every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16                         http_code=200 X-Served-By=poc1 announcer=poc1        200 and X-Served-By equals vip-takeover.sh --status
  PASS   X-Served-By never absent on the VIP                                    X-Served-By=poc1                                     the Gateway filter SET the header
  PASS   https://api.poc1.shop.poc.local @ 172.18.255.242                       http_code=200 X-Served-By=poc1                       200 and X-Served-By=poc1
  PASS   https://api.poc2.shop.poc.local @ 172.18.255.177                       http_code=200 X-Served-By=poc2                       200 and X-Served-By=poc2
  PASS   http://api.shop.poc.local @ 172.18.255.16 redirects                    http_code=301 Location=https://api.shop.poc.local:443/ 301 and exactly one Location beginning https://api.shop.poc.local/ (optional :443)
  PASS   http://api.poc1.shop.poc.local @ 172.18.255.242 redirects              http_code=301 Location=https://api.poc1.shop.poc.local:443/ 301 and exactly one Location beginning https://api.poc1.shop.poc.local/ (optional :443)
  PASS   http://api.poc2.shop.poc.local @ 172.18.255.177 redirects              http_code=301 Location=https://api.poc2.shop.poc.local:443/ 301 and exactly one Location beginning https://api.poc2.shop.poc.local/ (optional :443)
  PASS   poc1 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
  PASS   poc2 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
  PASS   poc1 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc1 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   poc2 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc2 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   VIP /healthz still 200 after policies                                  http_code=200 X-Served-By=poc1                       probe /healthz is 200 with the header
  PASS   X-Served-By never absent on /healthz                                   X-Served-By=poc1                                     the Gateway filter SET the header
```

`:80` with the HTTP Host header is a 301 to HTTPS (Location includes
`:443`). A bare IP (no Host match) is 404. `/ready` and `/orders`
answer 503 until phase 2: `api-gateway` proxies both to `backend`
(`shopapi`); `/ready` is `SELECT 1` against `db-service.poc.local`,
and there is no database yet (enhancement 002 R3). Readiness on the
backend Deployment is `/healthz` this phase.

Resources, measured 2026-09-18 beside the plan's §8 baseline (17.0 GiB
used, ~1.1 cores): node totals 396+244+200+167m CPU,
7431+5534+3351+3079 Mi; the four kind-node containers summed to
18.894 GiB. Delta vs §8: about +1.9 GiB RAM, CPU unchanged around one
core.

## What is deliberately not here

- The database, `db-gw`, and `toFQDNs` are demo 42 (enhancement 002
  R3). `/ready` and `/orders` stay 503.
- Scaling catalog to 0 to watch affinity fail over is scenario S2 of
  phase 5.
- cf2cnp's egress rule and a `default/unknown` policy with an empty
  `endpointSelector` are generator extras; phase 1's set is
  ingress-only (demo 35's model).
- `probe.sh` needs the `/etc/hosts` block. It never writes the file.
  `check.sh` and apply-both.sh pin the name.

## Clean up

```bash
demos/41-shop-mesh-phase1/cleanup.sh
```

Removes the HTTPRoutes, the generated policies, and the platform in
both clusters. KEPT: demo 40's doors (`shop-gw`, `shop-vip-gw`,
`shop-tls`), `shop-vip-announce`, `shared-vip-pool`, namespace
`shop-edge`.
