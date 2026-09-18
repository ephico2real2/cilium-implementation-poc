# Demo 50 — the vanilla lab's clusters

For the reader in a hurry: [RECAP.md](RECAP.md) — what this demo did and proved, in plain English.

**Where this sits in the whole:** [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
revision 2, §1 R1–R3, §3.1, §4 row 1, D5, D8, D10; tracking issue
[#55](https://github.com/ephico2real2/cilium-implementation-poc/issues/55)
(parent [#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53)).
Phase 0 measured the ground (`docs/EG-PHASE0.md`). This demo is the guide: both
clusters, the three-command Envoy Gateway install, cert-manager, and the lab
root. No load balancers, no Gateways, no apps — those are demos 51 and 52.

The `clusters/eg/probe-*.yaml` files are phase 0's record. They are **not**
applied here.

No docker build (gotcha #118 — nothing to build). poc1/poc2 stay paused
(gotcha #119). The `kind` network is not touched.

## Summary context — the enterprise case

"Installing Envoy Gateway" on bare metal is not one Helm chart. The Gateway API
CRDs are an upstream project with two channels; Envoy Gateway's chart bundles
the **experimental** channel and a single switch, `crds.enabled`, that is
all-or-nothing (Gateway API CRDs *and* Envoy Gateway's own eight CRDs). A
platform team that wants the standard channel only — the operator, 2026-09-18:
keep this lab clean; experimental features are another lab — therefore installs
three things, in order:

1. Upstream's `standard-install.yaml` (ten CRDs, every one annotated
   `channel: standard`).
2. The vendor's `gateway-crds-helm` with `crds.envoyGateway.enabled=true` and
   `crds.gatewayAPI.enabled=false` (the eight `gateway.envoyproxy.io` CRDs).
3. `gateway-helm` with `crds.enabled=false` (the controller, told its CRDs are
   already there).

The chart does not create a `GatewayClass`. That is a fourth apply.

This lab is the **second instance** of the reservation trick the Cilium lab
already uses on `kind` (`172.18.0.0/16`, Docker held to `/17`). `kind-eg` is a
separate bridge at `172.19.0.0/16` so the two labs never share a segment: four
load balancers and Cilium's L2 would otherwise ARP on the same LAN. Docker
allocates node addresses from `172.19.0.0/17` only; the reserved VIP `/24` at
`172.19.255.0/24` cannot become a node IP. Demos 51 and 52 put kube-vip and
MetalLB in that `/24`. They are not installed here.

A client from the Mac needs `sudo route -n add -net 172.19.0.0/16 192.168.64.2`
(phase 0 item 1). That route already exists on this Mac (recorded below). A
client from a container on `kind-eg` does not need it. No script in this
repository runs `sudo`.

## Files

| File | What |
|---|---|
| [`scripts/eg-up.sh`](../../scripts/eg-up.sh) | **the guide** — network, both clusters, the three-command install, GatewayClass, cert-manager, the shared root |
| [`scripts/eg-down.sh`](../../scripts/eg-down.sh) | deletes eg1, eg2 and `kind-eg` only |
| [`scripts/eg-net.sh`](../../scripts/eg-net.sh) | the `kind-eg` bridge (`--ip-range 172.19.0.0/17`, IPv6 ULA `fc00:f853:ccd:e794::/64`) |
| [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env) | the pins, including `CERT_MANAGER_VERSION=v1.21.1` |
| [`clusters/eg1.yaml`](../../clusters/eg1.yaml) / [`eg2.yaml`](../../clusters/eg2.yaml) | kind configs (kindnet + kube-proxy iptables; pods `10.50/16` / `10.60/16`) |
| [`clusters/eg/gatewayclass.yaml`](../../clusters/eg/gatewayclass.yaml) | `GatewayClass eg` — the chart does not create it |
| [`clusters/eg/eg-root-ca.yaml`](../../clusters/eg/eg-root-ca.yaml) | Issuer + CA Certificate + ClusterIssuer, applied on eg1 |
| [`clusters/eg/eg-ca-issuer.yaml`](../../clusters/eg/eg-ca-issuer.yaml) | ClusterIssuer only, applied on eg2 after the Secret is copied |
| [`clusters/eg/probe-*.yaml`](../../clusters/eg/) | phase 0's probes — **not** part of demo 50 |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | calls `scripts/eg-down.sh` (and says so) |
| [`GUIDE.md`](GUIDE.md) | three read-only exercises |
| [`output/transcript.txt`](output/transcript.txt) | every applied command, including the destroy |

The lab root PEM is **`.tmp/eg-root-ca.crt`** (gitignored). Issue #60: a
committed root drifts on every rebuild. The fingerprint is printed and checked;
the file is not in git.

## Steps

From the repo root. poc1/poc2 stay paused. The operator's instruction
(2026-09-18): *"destroy the new clusters and do them again using the newly
well-structured guide."*

```bash
scripts/eg-down.sh                 # first: delete phase 0's eg1 and kind-eg
scripts/eg-up.sh                   # the guide — both clusters, default
demos/50-eg-clusters/check.sh
```

`eg-up.sh` is idempotent (`scripts/eg-up.sh [eg1 eg2]`). Every command is
recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

### The destroy of phase 0's eg1 (quoted)

Recorded 2026-09-18T22:41:16Z, before anything was rebuilt. poc1/poc2 were
`Exited (137)` on the `kind` network and stayed that way. The Mac's route was
already there — no sudo.

```text
=== operator (2026-09-18): "destroy the new clusters and do them again using the newly well-structured guide" ===
$ bash -c netstat -rn -f inet | grep -E "^172\.(18|19)" || true
172.19             192.168.64.2       UGSc            bridge100

$ docker ps -a --format {{.Names}} {{.Status}} {{.Networks}}
eg1-worker Up 3 hours kind-eg
eg1-control-plane Up 3 hours kind-eg
poc2-control-plane Exited (137) 2 hours ago kind
poc2-worker Exited (137) 2 hours ago kind
poc1-control-plane Exited (137) 2 hours ago kind
poc1-worker Exited (137) 2 hours ago kind

$ scripts/eg-down.sh
Deleting cluster "eg1" ...
Deleted nodes: ["eg1-worker" "eg1-control-plane"]
kind-eg
```

Nothing from phase 0's hand-applied objects survived except what `eg-up.sh`
applies again (`GatewayClass eg`, and the pins). The probe Services, the
kube-vip and MetalLB installs, and the probe Gateways are gone.

### The rebuild

`eg-up.sh` (22:41:21Z–22:43:26Z). Gateway API CRDs are applied
**server-side** (`kubectl apply --server-side --force-conflicts`) so a rerun
does not fight phase 0's client-side field manager and so the CRDs do not
depend on the last-applied-configuration annotation. The URL is the same
`standard-install.yaml` v1.6.2 phase 0 applied.

The CRD chart **refused** `helm upgrade --install` on both clusters. Helm
stores a release in a Secret; the rendered CRDs exceed the 1 MiB limit:

```text
Error: create: failed to create: Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long: may not be more than 1048576 bytes
```

The guide fell back to phase 0's form — `helm template | kubectl apply
--server-side` — and recorded why. `helm list -n envoy-gateway-system` therefore
shows `eg` (the controller) and not `eg-crds`. The eight CRDs are present.

Final table from this run:

```text
CLUSTER  NODES/IPs                                        KUBEPROXY  GW_API       EG_CRDS  GATEWAYCLASS ENVOY-GATEWAY  CERT-MANAGER   ROOT_SHA256
eg1      eg1-control-plane=172.19.0.2 eg1-worker=172.19.0.3  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
eg2      eg2-control-plane=172.19.0.4 eg2-worker=172.19.0.5  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
```

`check.sh` (exit 0), recorded 2026-09-18T22:43:56Z:

```text
  PASS   eg1 / eg2 nodes Ready                                                  Ready=2
  PASS   node IPs in 172.19.0.0/17, none in 172.19.255.0/24                     .2/.3 and .4/.5
  PASS   kindnet 2/2, kube-proxy mode iptables, grep -c cilium=0
  PASS   10 Gateway API CRDs channel=standard v1.6.2, 8 gateway.envoyproxy.io
  PASS   helm list shows eg (eg-crds not a release)
  PASS   GatewayClass eg Accepted, envoy-gateway Available, cert-manager Available
  PASS   ClusterIssuer eg-ca-issuer Ready; root fingerprint identical
  PASS   kind-eg ip-range 172.19.0.0/17; host route 172.19/16 present
demo 50 check: 0 FAIL
```

## What was measured

**The destroy.** `scripts/eg-down.sh` had only been syntax-checked in phase 0.
It deleted eg1 (`eg1-worker`, `eg1-control-plane`) and then `docker network rm
kind-eg`. poc1/poc2 stayed `Exited (137)` on `kind`. The `kind` network was not
removed.

**The network, recreated.** `scripts/eg-net.sh` created `kind-eg` with
`172.19.0.0/16`, `ip-range=172.19.0.0/17`, `gateway=172.19.0.1`, and IPv6 ULA
`fc00:f853:ccd:e794::/64`. Docker inspect prints `ip-range=invalid Prefix` on
the IPv6 block (no `--ip-range` was passed for it). `check.sh` reads the IPv4
block only.

**Node addresses.** eg1 landed on `172.19.0.2` / `172.19.0.3`; eg2 on
`172.19.0.4` / `172.19.0.5`. All four sit inside `172.19.0.0/17`. None in
`172.19.255.0/24`. kind still prints "Here be dragons" for
`KIND_EXPERIMENTAL_DOCKER_NETWORK`.

**Stock networking.** `kindnet` and `kube-proxy` DaemonSets 2/2 on both
clusters; kube-proxy ConfigMap `mode: iptables`; `kubectl get ds -A | grep -c
cilium` = 0.

**The CRD chart cannot be a Helm release.** `helm upgrade --install eg-crds`
failed on both clusters with `Secret "sh.helm.release.v1.eg-crds.v1" is
invalid: data: Too long: may not be more than 1048576 bytes`. The fallback is
the form phase 0 measured. The controller chart (`gateway-helm`,
`crds.enabled=false`) installs as release `eg` on both.

**Standard channel only (D10).** All ten `gateway.networking.k8s.io` CRDs carry
`channel: standard` and `bundle-version: v1.6.2`. The eight
`gateway.envoyproxy.io` CRDs are present. `check.sh` fails loudly if either
annotation drifts.

**The same root, not committed (D8, issue #60).** Created in eg1 (`CN=eg-root-ca`,
isCA, 10 years), Secret copied to eg2, `ClusterIssuer/eg-ca-issuer` Ready in
both. SHA-256 fingerprint
`6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16`
on both. Exported to `.tmp/eg-root-ca.crt`.

## Known limitations

`eg-crds` is not a Helm release. Upgrades of Envoy Gateway's CRDs are
`helm template | kubectl apply --server-side` until the chart fits in a Helm
Secret (or Helm grows another store). The controller *is* a release.

There are no load balancers and no Gateways. `kubectl get gateway,svc -A` has
nothing of the lab's in the reserved `/24`. That is this phase, not a gap.

`eg-up.sh` does not check the Mac route (Linux-runner safe). `check.sh` WARNs,
and prints the sudo command, if the route is absent.

## Cleanup

```bash
demos/50-eg-clusters/cleanup.sh
```

That script calls `scripts/eg-down.sh`. It deletes eg1, eg2 and `kind-eg`. It
does not touch poc1, poc2, CRC, or the `kind` network.

## Where demos 51 and 52 start

Demo 51 installs kube-vip (DaemonSet + cloud-provider + the three class
filters phase 0 measured) and creates the Gateways with an `EnvoyProxy` that
already has `loadBalancerClass` at create time. Demo 52 does the same with
MetalLB (`frrk8s.enabled=false`, `speaker.frr.enabled=false`). Both reuse
these clusters, this `GatewayClass`, and this root. Do not rebuild the
clusters in those demos unless `eg-down.sh` / `eg-up.sh` is the point of the
run.
