# Demo 50 — the vanilla lab's clusters

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

**Where this sits in the whole:** [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
revision 2, §1 R1–R3, §3.1, §4 row 1, D5, D8, D10; tracking issue
[#55](https://github.com/ephico2real2/cilium-implementation-poc/issues/55)
(parent [#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53)).
Phase 0 measured the ground (`docs/EG-PHASE0.md`). This demo is both
clusters, the three-command Envoy Gateway install, cert-manager, and the
lab root. No load balancers, no Gateways, no apps — those are demos 51
and 54.

The `clusters/eg/probe-*.yaml` files are phase 0's record. They are
**not** applied here. No docker build (gotcha #118). poc1/poc2 stay
paused (gotcha #119). The `kind` network is not touched.

## Summary context — the enterprise case

"Installing Envoy Gateway" on bare metal is not one Helm chart. The
Gateway API CRDs are an upstream project with two channels; Envoy
Gateway's chart bundles the **experimental** channel and a single
switch, `crds.enabled`, that is all-or-nothing. A platform team that
wants the standard channel only — the operator, 2026-09-18: keep this
lab clean; experimental features are another lab — therefore installs
three things, in order:

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side --force-conflicts -f -
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 -n envoy-gateway-system --create-namespace \
  --set crds.enabled=false
```

The chart does not create a `GatewayClass`. That is a fourth apply.

This lab is the **second instance** of the reservation trick the Cilium
lab already uses on `kind` (`172.18.0.0/16`, Docker held to `/17`).
`kind-eg` is a separate bridge at `172.19.0.0/16` so the two labs never
share a segment. Docker allocates node addresses from `172.19.0.0/17`
only; the reserved VIP `/24` at `172.19.255.0/24` cannot become a node
IP. Demos 51 and 54 put kube-vip (and 52, MetalLB) in that `/24`. They
are not installed here.

A client from the Mac needs the route under
[RECAP.md](RECAP.md) *Prerequisites* (phase 0 item 1). That route
already exists on this Mac (recorded in *Checks*). A client from a
container on `kind-eg` does not need it. No script in this repository
runs `sudo`.

## Files

| File | What |
|---|---|
| [`scripts/eg-up.sh`](../../scripts/eg-up.sh) | network, both clusters, the three-command install, GatewayClass, cert-manager, the shared root |
| [`scripts/eg-down.sh`](../../scripts/eg-down.sh) | deletes `eg1`, `eg2`, `eg-poc1`, and `kind-eg` only |
| [`scripts/eg-net.sh`](../../scripts/eg-net.sh) | the `kind-eg` bridge (`--ip-range 172.19.0.0/17`, IPv6 ULA `fc00:f853:ccd:e794::/64`) |
| [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env) | the pins, including `CERT_MANAGER_VERSION=v1.21.1` |
| [`clusters/eg1.yaml`](../../clusters/eg1.yaml) / [`eg2.yaml`](../../clusters/eg2.yaml) | kind configs (kindnet + kube-proxy iptables; pods `10.50/16` / `10.60/16`) |
| [`clusters/eg/gatewayclass.yaml`](../../clusters/eg/gatewayclass.yaml) | `GatewayClass eg` — the chart does not create it |
| [`clusters/eg/eg-root-ca.yaml`](../../clusters/eg/eg-root-ca.yaml) | Issuer + CA Certificate + ClusterIssuer, applied on `eg1` |
| [`clusters/eg/eg-ca-issuer.yaml`](../../clusters/eg/eg-ca-issuer.yaml) | ClusterIssuer only, applied on `eg2` after the Secret is copied |
| [`clusters/eg/probe-*.yaml`](../../clusters/eg/) | phase 0's probes — **not** part of demo 50 |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | calls `scripts/eg-down.sh` (and says so) |
| [`GUIDE.md`](GUIDE.md) | four read-only exercises |
| [`output/transcript.txt`](output/transcript.txt) | every applied command |

The lab root PEM is **`.tmp/eg-root-ca.crt`** (gitignored). Issue #60: a
committed root drifts on every rebuild. The fingerprint is printed and
checked; the file is not in git.

## Run it

From the repo root. poc1/poc2 stay paused. `eg-up.sh` is idempotent
(`eg1` is always built first and holds the root). Every command is
recorded through record.sh into
[`output/transcript.txt`](output/transcript.txt) (append, never
truncate). The last run is `2026-09-18T23:15:29Z`.

```bash
scripts/eg-up.sh
demos/50-eg-clusters/check.sh
```

## What was recorded

One H3 per step of `eg-up.sh`, quoted from the last run
(`2026-09-18T23:15:29Z`). Create is skipped when the object exists; the
IPs, counts, Accepted, and fingerprint are the same as the first build.

### 1. Create the network

```bash
scripts/eg-net.sh
docker network inspect kind-eg --format \
  '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'
```

```text
exists with 172.19.0.0/16, kept
subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1
subnet=fc00:f853:ccd:e794::/64 ip-range=invalid Prefix gateway=fc00:f853:ccd:e794::1
```

### 2. Create the clusters

The last run found both clusters already up (same node IPs as the
create). kindnet and kube-proxy `2/2`; kube-proxy ConfigMap
`mode: iptables`.

```bash
kubectl --context kind-eg1 wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context kind-eg1 get nodes -o wide
kubectl --context kind-eg2 wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context kind-eg2 get nodes -o wide
```

```text
node/eg1-control-plane condition met
node/eg1-worker condition met
eg1-control-plane   Ready    control-plane   34m   v1.36.4   172.19.0.2    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg1-worker          Ready    <none>          33m   v1.36.4   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg1-control-plane 172.19.0.2
eg1-worker 172.19.0.3
    mode: iptables
node/eg2-control-plane condition met
node/eg2-worker condition met
eg2-control-plane   Ready    control-plane   33m   v1.36.4   172.19.0.4    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg2-worker          Ready    <none>          33m   v1.36.4   172.19.0.5    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg2-control-plane 172.19.0.4
eg2-worker 172.19.0.5
```

### 3. Install the Gateway API standard CRDs

Server-side apply of `standard-install.yaml` v1.6.2, then the channel
assertion. Both clusters: ten CRDs, every one `channel=standard`
`bundle-version=v1.6.2`.

```bash
kubectl --context kind-eg1 apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
```

```text
gateway.networking.k8s.io CRDs: 10 (want 10)
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/listenersets.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/tcproutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/tlsroutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
```

### 4. Install Envoy Gateway's CRDs

The last run goes straight to the vendor-prescribed pipe. A Helm
release of `gateway-crds-helm` v1.9.1 cannot store its Secret (measured
on the first build, both clusters) — that is why the pipe is the
method
([helm/helm#12277](https://github.com/helm/helm/issues/12277)):

```text
Error: create: failed to create: Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long: may not be more than 1048576 bytes
```

```bash
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl --context kind-eg1 apply --server-side --force-conflicts -f -
```

```text
gateway.envoyproxy.io CRDs: 8 (want 8)
customresourcedefinition.apiextensions.k8s.io/backends.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/backendtrafficpolicies.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/clienttrafficpolicies.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/envoyextensionpolicies.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/envoypatchpolicies.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/envoyproxies.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/httproutefilters.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/securitypolicies.gateway.envoyproxy.io
```

The Helm list in `envoy-gateway-system` therefore shows `eg` (the
controller) and not `eg-crds`.

### 5. Install the Envoy Gateway controller

`gateway-helm` v1.9.1, `crds.enabled=false`, release `eg`.

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 -n envoy-gateway-system --create-namespace \
  --kube-context kind-eg1 --set crds.enabled=false
```

```text
Release "eg" has been upgraded. Happy Helming!
NAME: eg
NAMESPACE: envoy-gateway-system
STATUS: deployed
deployment "envoy-gateway" successfully rolled out
```

### 6. Create the GatewayClass

```bash
kubectl --context kind-eg1 apply -f clusters/eg/gatewayclass.yaml
kubectl --context kind-eg1 wait --for=condition=Accepted gatewayclass/eg --timeout=60s
```

```text
gatewayclass.gateway.networking.k8s.io/eg unchanged
gatewayclass.gateway.networking.k8s.io/eg condition met
```

### 7. Install cert-manager and the lab root

Mint on `eg1` (`clusters/eg/eg-root-ca.yaml`). Copy the Secret
server-side to `eg2`; apply `clusters/eg/eg-ca-issuer.yaml` there.

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.1 --namespace cert-manager --create-namespace \
  --kube-context kind-eg1 --set crds.enabled=true --wait --timeout 5m
kubectl --context kind-eg1 apply -f clusters/eg/eg-root-ca.yaml
```

```text
cert-manager v1.21.1 has been deployed successfully!
certificate.cert-manager.io/eg-root-ca condition met
clusterissuer.cert-manager.io/eg-ca-issuer condition met
secret/eg-root-ca serverside-applied
```

### 8. Export the root

PEM to `.tmp/eg-root-ca.crt` (gitignored; issue #60). Same sha256 on
both clusters.

```bash
openssl x509 -in .tmp/eg-root-ca.crt -noout -subject -issuer -fingerprint -sha256
```

```text
subject=CN=eg-root-ca
issuer=CN=eg-root-ca
sha256 Fingerprint=6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
CLUSTER  NODES/IPs                                        KUBEPROXY  GW_API       EG_CRDS  GATEWAYCLASS ENVOY-GATEWAY  CERT-MANAGER   ROOT_SHA256
eg1      eg1-control-plane=172.19.0.2 eg1-worker=172.19.0.3  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
eg2      eg2-control-plane=172.19.0.4 eg2-worker=172.19.0.5  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
```

## Checks

`check.sh` (exit 0), recorded `2026-09-18T23:15:58Z` — the 27 rows
verbatim:

```text
== demo 50 — the vanilla lab's clusters (enhancement 007 phase 1)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   eg1 nodes Ready                                                        Ready=2                                              R2 — every node Ready
  PASS   eg1 node IPs in 172.19.0.0/17, none in 172.19.255.0/24                 eg1-control-plane=172.19.0.2 eg1-worker=172.19.0.3   R1 / §3.1 — Docker --ip-range 172.19.0.0/17
  PASS   eg1 kindnet DaemonSet                                                  ready=2/2                                            R2 — kindnet present
  PASS   eg1 kube-proxy mode iptables                                           ds=2/2 mode=iptables                                 R2 — kube-proxy present, mode iptables
  PASS   eg1 no Cilium DaemonSet or CRD                                         ds=0 crd=0                                           R2 — kubectl get ds -A / get crd | grep -c cilium = 0
  PASS   eg1 10 Gateway API CRDs channel=standard v1.6.2                        n=10 bad=0 ver=v1.6.2                                D10 / R3 — every gateway.networking.k8s.io CRD channel: standard, bundle-version v1.6.2
  PASS   eg1 8 gateway.envoyproxy.io CRDs                                       n=8                                                  R3 — Envoy Gateway's own CRDs from gateway-crds-helm
  PASS   eg1 helm list shows eg (eg-crds not a release)                         eg                                                   R3 — helm list -n envoy-gateway-system shows eg (and eg-crds if a release)
  PASS   eg1 GatewayClass eg Accepted                                           Accepted=True                                        R3 — GatewayClass eg Accepted (chart does not create it)
  PASS   eg1 envoy-gateway Deployment Available                                 Available=True                                       R3 — envoy-gateway Deployment Available
  PASS   eg1 cert-manager Deployment Available                                  Available=True                                       D8 — cert-manager v1.21.1 Available for the lab root
  PASS   eg1 ClusterIssuer eg-ca-issuer Ready                                   Ready=True                                           D8 — ClusterIssuer eg-ca-issuer Ready
  PASS   eg2 nodes Ready                                                        Ready=2                                              R2 — every node Ready
  PASS   eg2 node IPs in 172.19.0.0/17, none in 172.19.255.0/24                 eg2-control-plane=172.19.0.4 eg2-worker=172.19.0.5   R1 / §3.1 — Docker --ip-range 172.19.0.0/17
  PASS   eg2 kindnet DaemonSet                                                  ready=2/2                                            R2 — kindnet present
  PASS   eg2 kube-proxy mode iptables                                           ds=2/2 mode=iptables                                 R2 — kube-proxy present, mode iptables
  PASS   eg2 no Cilium DaemonSet or CRD                                         ds=0 crd=0                                           R2 — kubectl get ds -A / get crd | grep -c cilium = 0
  PASS   eg2 10 Gateway API CRDs channel=standard v1.6.2                        n=10 bad=0 ver=v1.6.2                                D10 / R3 — every gateway.networking.k8s.io CRD channel: standard, bundle-version v1.6.2
  PASS   eg2 8 gateway.envoyproxy.io CRDs                                       n=8                                                  R3 — Envoy Gateway's own CRDs from gateway-crds-helm
  PASS   eg2 helm list shows eg (eg-crds not a release)                         eg                                                   R3 — helm list -n envoy-gateway-system shows eg (and eg-crds if a release)
  PASS   eg2 GatewayClass eg Accepted                                           Accepted=True                                        R3 — GatewayClass eg Accepted (chart does not create it)
  PASS   eg2 envoy-gateway Deployment Available                                 Available=True                                       R3 — envoy-gateway Deployment Available
  PASS   eg2 cert-manager Deployment Available                                  Available=True                                       D8 — cert-manager v1.21.1 Available for the lab root
  PASS   eg2 ClusterIssuer eg-ca-issuer Ready                                   Ready=True                                           D8 — ClusterIssuer eg-ca-issuer Ready
  PASS   root fingerprint identical in both clusters                            6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16 D8 — the SAME root in both clusters (copied Secret)
  PASS   kind-eg ip-range is 172.19.0.0/17                                      172.19.0.0/17                                        R1 / §3.1 — docker network inspect kind-eg ip-range
  PASS   host route 172.19/16 present                                           172.19             192.168.64.2       UGSc            bridge100        phase 0 item 1 — Mac route 172.19/16 (WARN if absent)

demo 50 check: 0 FAIL
```

## What is deliberately not here

- No load balancer, no Gateway, no app. The reserved `/24` is empty.
  That is this phase, not a gap.
- `clusters/eg/probe-*.yaml` stay on disk; they are not applied.
- The experimental Gateway API channel is not installed (D10).
- poc1, poc2, CRC, and the `kind` network are not touched.
- `eg-crds` is not a Helm release. Upgrades of Envoy Gateway's CRDs are
  the same pipe as step 4.

## Clean up

```bash
demos/50-eg-clusters/cleanup.sh
```

That script calls eg-down.sh. It deletes `eg1`, `eg2`, `eg-poc1`, and
`kind-eg`. It does not touch poc1, poc2, CRC, or the `kind` network.
