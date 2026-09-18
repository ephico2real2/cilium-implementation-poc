# Demo 51 — Envoy Gateway with kube-vip, alone

For the reader in a hurry: [RECAP.md](RECAP.md) — what this demo did and proved, in plain English.

**Where this sits in the whole:** [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
revision 2, §1 R4/R7/R8/R10, §3.1 the address plan, §3.3 the static-address
experiment, §3.4 the doors, §4 row 2, D3/D8/D10/D11; tracking issue
[#56](https://github.com/ephico2real2/cilium-implementation-poc/issues/56)
(parent [#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53)).
Demo 50 built the clusters and the controller. This demo hangs kube-vip on
them and opens the doors. MetalLB is **not** installed — that is demo 52.
The operator, 2026-09-18: *"I would like to run the envoy proxy in separate
demo with kube-vip alone."*

No docker build (gotcha #118 — `kind load` of existing `shopapi:local` and
`routedemo:local` is not a build). poc1/poc2 stay paused (gotcha #119). The
`kind` network is not touched.

## Summary context — the enterprise case

The contract a team learns: **the `EnvoyProxy` attached to their Gateway
names the load balancer and the address; the platform's load balancer claims
nothing else.** On the Gateway they set `infrastructure.parametersRef` to an
`EnvoyProxy` whose `envoyService.loadBalancerClass` is
`kube-vip.io/kube-vip-class` and whose annotation
`kube-vip.io/loadbalancerIPs` pins the IP. kube-vip is started class-only
(`lb_class_only=true` on the DaemonSet, `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`
on the cloud-provider), so a Service that forgets the class stays
`<pending>` — `probe-noclass` in `shop` is the standing exhibit. That is
the best practice the operator asked for (D11): *"I need to have
loadBalancerClass — this best practice that we will get to use eventually
and allow us to train application teams."* When MetalLB arrives in demo 52
the same contract picks the other class; a class-less Service is still
nobody's.

The class is immutable on the generated Service. Phase 0 measured that
attaching an `EnvoyProxy` after the Gateway exists fails with
`spec.loadBalancerClass: may not change once set`. The `EnvoyProxy` is
created in the same file, before the Gateway.

`Gateway.spec.addresses` alone writes `externalIPs` and nobody answers ARP
(R7, re-measured below). The annotation on the `EnvoyProxy` is what kube-vip
announces. Both are set so `status.addresses` stays honest and the wire
answers.

The Gateways live in `shop` with the certificate Secret, so Envoy Gateway
does not need a ReferenceGrant.

## Files

| File | What |
|---|---|
| [`clusters/eg/kube-vip-rbac.yaml`](../../clusters/eg/kube-vip-rbac.yaml), [`kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml), [`kube-vip-cloud-provider.yaml`](../../clusters/eg/kube-vip-cloud-provider.yaml) | **one source of truth** — phase 0's working objects (v1.2.4 ARP + `svc_election` + `lb_class_only`, no taint; cloud-provider v0.0.12 with the class env). Not copied. `clusters/eg/probe-*.yaml` are phase 0's record and are not applied |
| [`10-kubevip-cm-eg1.yaml`](10-kubevip-cm-eg1.yaml) / [`10-kubevip-cm-eg2.yaml`](10-kubevip-cm-eg2.yaml) | the `kubevip` ConfigMap per cluster (§3.1) |
| [`00-namespaces.yaml`](00-namespaces.yaml) | namespace `shop` |
| [`15-probe-noclass.yaml`](15-probe-noclass.yaml) | D11 standing exhibit — class-less LoadBalancer, stays `<pending>` |
| [`20-certificates.yaml`](20-certificates.yaml) | one `Certificate` `eg-tls` in `shop`, CN `api.eg.poc.local`, six SANs |
| [`30-gateways-eg1.yaml`](30-gateways-eg1.yaml) / [`30-gateways-eg2.yaml`](30-gateways-eg2.yaml) | two files (demo 40's choice): EnvoyProxy then Gateway, per-cluster door + VIP door. apply.sh / `eg-vip-move.sh` apply the VIP pair to one cluster at a time |
| [`40-app.yaml`](40-app.yaml) | `shopapi` + `grpc` (`routedemo:local -mode grpc`, `appProtocol: kubernetes.io/h2c`) |
| [`50-routes-eg1.yaml`](50-routes-eg1.yaml) / [`50-routes-eg2.yaml`](50-routes-eg2.yaml) | per-cluster routes always; VIP routes (`shop-api-vip`, `shop-redirect-vip`, `grpc-vip`) only where `eg-vip-gw` is |
| [`apply.sh`](apply.sh) | idempotent; every step through `scripts/record.sh` |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | doors, app, kube-vip, `shop` — leaves demo 50's clusters |
| [`hosts-entries.sh`](hosts-entries.sh) | the six names from live Gateway addresses; never writes `/etc/hosts` |
| [`scripts/eg-vip-move.sh`](../../scripts/eg-vip-move.sh) | delete-other-first; `--status` prints who has `.16` and the ARP responder |
| [`GUIDE.md`](GUIDE.md) | three exercises |
| [`output/transcript.txt`](output/transcript.txt) | every applied command |

The lab root PEM is **`.tmp/eg-root-ca.crt`** (gitignored, issue #60).

## Steps

From the repo root. poc1/poc2 stay paused. eg1 and eg2 are already up
(`scripts/eg-up.sh`).

```bash
demos/51-eg-kube-vip/apply.sh
demos/51-eg-kube-vip/check.sh
```

`VIP_HOME` defaults to `eg1`. Every command is recorded through
`scripts/record.sh` into [`output/transcript.txt`](output/transcript.txt)
(append, never truncate).

### kube-vip on both clusters

Phase 0 files, plus the per-cluster ConfigMap. DS 2/2 and cloud-provider
Available on both. `kubectl get ns metallb-system` is `NotFound` on both.

```text
$ kubectl --context kind-eg1 -n kube-system rollout status ds/kube-vip-ds --timeout=120s
daemon set "kube-vip-ds" successfully rolled out
$ kubectl --context kind-eg1 -n kube-system wait deploy/kube-vip-cloud-provider --for=condition=Available --timeout=120s
deployment.apps/kube-vip-cloud-provider condition met
```

### The doors

Envoy Gateway accepted two HTTPS listeners on `:443` with different
hostnames (`api.eg1.poc.local` and `grpc.eg1.poc.local`). Programmed in
11 s (eg1) / 10 s (eg2). The VIP Gateway was created on eg1 only;
`arping 172.19.255.16` returned 3 of 3 from `eg1-worker`
(`6e:8c:28:fa:31:1f`).

```text
CLUSTER  DOOR       ADDRESS          PROG   LB_CLASS                     ANNOUNCED_BY           HTTP         GRPC_H2C   GRPC_TLS
eg1      eg1-gw     172.19.255.240   True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg1      eg-vip-gw  172.19.255.16    True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg2      eg2-gw     172.19.255.176   True   kube-vip.io/kube-vip-class   eg2-worker             200/eg2      SERVING    SERVING
```

`check.sh` (exit 0), recorded 2026-09-18T23:56:44Z — 39 PASS, 0 FAIL. The
rows name R4, R7, R8, R10 or D11. The verbatim table is in the transcript.

## What was measured

**R7 — `spec.addresses` alone is configured and silent.** A throwaway
Gateway `probe-noproxy` in `shop` with `spec.addresses: .245` (eg1) /
`.181` (eg2) and no `EnvoyProxy`. The generated Service had
`externalIPs=['172.19.255.245']` (eg1) / `['172.19.255.181']` (eg2) and
`status.loadBalancer={}`. `arping` from a container on `kind-eg`:
**Received 0 response(s)** on both clusters. Then deleted.

**The VIP move.** `scripts/eg-vip-move.sh kube-vip eg2` deletes
`eg-vip-gw` + its routes + its `EnvoyProxy` from eg1 first, then creates
them on eg2. Before: 3 of 3 from `eg1-worker`. After: 3 of 3 from
`eg2-control-plane` (`1e:c6:bf:d8:18:97`). A `curl -m 1` every 0.5 s
during the move: **32 samples, 23 ok, 9 fail, gap 10.486 s**. Back to
eg1: responder returned to `eg1-worker`; **32 samples, 24 ok, 8 fail,
gap 8.976 s**. Creating the VIP Gateway on eg2 did **not** fail with
".16 in use" — kube-vip accepted the annotation after the other
cluster's Service was gone.

**gRPC (R10).** `appProtocol: kubernetes.io/h2c` on Service `grpc:9090`
was enough. No `BackendTrafficPolicy`. `grpcurl -plaintext -authority
grpc.eg1.poc.local 172.19.255.240:80 grpc.health.v1.Health/Check` →
`SERVING`; the same with `-cacert .tmp/eg-root-ca.crt` on `:443`;
`list` via reflection printed `grpc.health.v1.Health` and both
reflection services. Repeated on `.176` and `.16`.

**Two HTTPS listeners on one port.** Envoy Gateway Accepted both
(`https` + `https-grpc` on `:443`). The brief's stop-condition did not
fire.

**`kind load`.** `shopapi:local` and `routedemo:local` loaded on the
first apply (single-image tags). The second apply skipped them —
`crictl images` on every node already showed them. No docker build.

**shopctl.** `api.eg.poc.local` does not resolve on this Mac (no
`/etc/hosts` write — no sudo). apply.sh WARNed and printed the hosts
block. Checks use `--resolve`.

**The first apply** stopped at VIP routes: `yaml_select` looked for a
block-style `name:` and the route files use compact
`metadata: {name: …}`. Fixed; the second apply (23:54:49Z) completed.

## Known limitations

`shopctl probe` needs `/etc/hosts`. apply.sh does not write it (no sudo).
The operator adds the block from `hosts-entries.sh`. `--resolve` and
`-authority` cover every check.

There is no MetalLB and no Cilium policy. That is this demo, not a gap.

The VIP move's gap is the time to delete the Gateway, roll a new Envoy
Deployment on the other cluster, and wait for it Available — seconds,
not the ~40 ms Cilium lease move in demo 40. The announcer *is* the
Gateway.

## Cleanup

```bash
demos/51-eg-kube-vip/cleanup.sh
```

Removes the routes, app, Gateways + EnvoyProxies, certificate + secret,
kube-vip, the ConfigMaps, and namespace `shop`. Leaves demo 50's
clusters, Envoy Gateway, `GatewayClass eg`, cert-manager, and
`.tmp/eg-root-ca.crt`. Does not touch poc1, poc2, CRC, or the `kind`
network.

## Where demo 52 starts

Demo 52 installs MetalLB (`--lb-class`, `frrk8s.enabled=false`) beside
this kube-vip, gives the same doors the other class and the MetalLB
addresses (`.246` / `.182`, VIP `.17`), repeats R7, and writes the
side-by-side table. Do not uninstall kube-vip for that — D3/D11 are
the coexistence the team is being trained on.
