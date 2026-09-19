# Demo 41 — five things to try

Five exercises against the demo once it is up; nothing here changes
the cluster except the hosts block under Prerequisites.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- poc1 and poc2 are up; demo 40's doors are present.
- The hosts block — the one sudo step (the script only prints the
  lines; the `tee` writes them). `probe.sh` needs it; these curls pin
  the name and do not:

```bash
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Exercises

### 1. Call the three doors

Each HTTPRoute sets `X-Served-By` to the cluster that served the door.
The VIP's value equals whoever announces `172.18.255.16` (poc1 in this
record).

```bash
curl -sk --resolve api.shop.poc.local:443:172.18.255.16 \
  https://api.shop.poc.local/ -D - -o /dev/null
curl -sk --resolve api.poc1.shop.poc.local:443:172.18.255.242 \
  https://api.poc1.shop.poc.local/ -D - -o /dev/null
curl -sk --resolve api.poc2.shop.poc.local:443:172.18.255.177 \
  https://api.poc2.shop.poc.local/ -D - -o /dev/null
```

**Expect:** the recorded header lines. `.242` is `poc1`, `.177` is
`poc2`. The header names the door, not whether `api-gateway`'s
upstream was local or remote.

```text
HTTP/2 200
x-served-by: poc1
x-served-by: poc2
```

### 2. Read catalog backends under affinity local

`cilium-dbg service list` prints the selected set. statedb holds the
remote copy (`Source: clustermesh`); the BPF map does not while a
local backend is Active
(`pkg/clustermesh/selectbackends.go`).

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg service list
```

**Expect:** the recorded selected backends. check.sh measured both
numbers: `known=2 (clustermesh=1) selected=1 local` on each cluster.

```text
-- kind-poc1 catalog ClusterIP=10.11.58.134
-- annotations global=true affinity=local
172   10.11.58.134:80/TCP       ClusterIP      1 => 10.10.0.46:80/TCP (active)
-- kind-poc2 catalog ClusterIP=10.21.123.1
95   10.21.123.1:80/TCP       ClusterIP      1 => 10.20.0.135:80/TCP (active)
  PASS   poc1 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
  PASS   poc2 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
```

### 3. Compare the generated policies

Seven CiliumNetworkPolicies per cluster, same descriptions, no
cluster label on the selectors (local cluster only, Cilium 1.19+).

```bash
kubectl --context kind-poc1 get cnp -A -l app.kubernetes.io/managed-by=cf2cnp
```

**Expect:** the recorded inventory, `7/7 exact names` on both
clusters.

```text
  PASS   poc1 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc2 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
```

### 4. Confirm the stranger is dropped

Shopper goes through `api-gateway`. The stranger is not in catalog's
selector. This reads Hubble; it does not change any object.

```bash
kubectl --context kind-poc1 -n shop-clients exec stranger -- \
  wget -qO- --timeout=3 http://catalog.shop-core/healthz
```

**Expect:** the recorded timeout, then Hubble `DROPPED` /
`FORWARDED` (the same measurement as `verify_enforcement`).

```text
stranger -> catalog: expected failure rc=1 output=wget: download timed out
  DROPPED stranger -> catalog-5799bdf56f-qbv7m shop-core DROPPED
  FORWARDED api-gateway-c448767bb-sljk4 -> catalog-5799bdf56f-qsd4p FORWARDED
kind-poc1: DROPPED stranger->catalog and FORWARDED api-gateway->catalog observed
```

### 5. Run the check

```bash
demos/41-shop-mesh-phase1/check.sh
```

**Expect:** 33 PASS, 0 FAIL, 0 WARN. The recorded VIP and `/healthz`
rows:

```text
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16                         http_code=200 X-Served-By=poc1 announcer=poc1        200 and X-Served-By equals vip-takeover.sh --status
  PASS   VIP /healthz still 200 after policies                                  http_code=200 X-Served-By=poc1                       probe /healthz is 200 with the header
```

`/ready` and `/orders` answer 503 until phase 2 (enhancement 002 R3 —
no database).

## Clean up

[README Clean up](README.md#clean-up).
