# Demo 50 — two kind clusters, the Gateway API standard channel, Envoy Gateway, and one lab root

This page stands up the two-cluster Envoy Gateway lab: `eg1` and `eg2` on a
Docker bridge of their own, stock networking (kindnet and kube-proxy in
iptables mode, no Cilium), the Gateway API CRDs from the standard channel,
Envoy Gateway as the implementation, and one lab root. The root is minted
on `eg1` and copied server-side to `eg2`, so both ClusterIssuers sign from
the same key. Nothing here is a load balancer, a Gateway, or an app —
those arrive in demos 51 and 54. What it proves is the reservation, the
channel annotations, `GatewayClass` Accepted, and the same sha256 on both
clusters.

## What you get

- Docker network `kind-eg` at `172.19.0.0/16` with allocation held to
  `172.19.0.0/17`; nodes `.2` / `.3` / `.4` / `.5`, none in
  `172.19.255.0/24`.
- Both clusters: kindnet + kube-proxy `iptables`, Cilium DaemonSet 0,
  Cilium CRD 0.
- Ten `gateway.networking.k8s.io` CRDs, every one `channel: standard` and
  `bundle-version: v1.6.2`.
- Eight `gateway.envoyproxy.io` CRDs from Envoy Gateway v1.9.1; the Helm
  list in `envoy-gateway-system` shows release `eg` only.
- `GatewayClass eg` `Accepted=True`; envoy-gateway `1/1`; cert-manager
  v1.21.1 `Available=True`.
- One root, sha256
  `6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16`
  on both clusters and in `.tmp/eg-root-ca.crt`.
- `check.sh` at `2026-09-18T23:15:58Z`: 27 PASS, 0 FAIL.

## Architecture

The reservation trick holds Docker's node addresses to the lower `/17` so
the top `/24` can never be a node IP. That `/24` is carved into the `/26`
blocks in [enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md).
They stay empty until demos 51 and 54 announce from them.

```text
                         Mac  ── route 172.19/16 → 192.168.64.2 ──  Docker VM
                                                                    │
                         docker network kind-eg   172.19.0.0/16
                         Docker allocates from 172.19.0.0/17 only
                         IPv6 ULA fc00:f853:ccd:e794::/64
                         reserved VIP /24: 172.19.255.0/24
                                    │
              ┌─────────────────────┴──────────────────────┐
              │  eg1                    │  eg2             │
              │  .0.2 control-plane     │  .0.4 cp         │
              │  .0.3 worker            │  .0.5 worker     │
              │  pods 10.50.0.0/16      │  pods 10.60.0.0/16│
              │  svc  10.51.0.0/16      │  svc  10.61.0.0/16│
              │  kindnet + kube-proxy   │  same            │
              │  GatewayClass eg        │  GatewayClass eg │
              │  envoy-gateway 1/1      │  envoy-gateway   │
              │  cert-manager + root    │  same Secret     │
              │  reserved .192/26       │  reserved .128/26│
              │  (empty)                │  (empty)         │
              └─────────────────────────┴──────────────────┘
                         shared .0/26   (empty)
                         eg-poc1 .64/26 (demo 54)
```

| Cluster | Nodes | Pod CIDR | Service CIDR | Reserved block |
|---|---|---|---|---|
| `eg1` | `172.19.0.2` / `172.19.0.3` | `10.50.0.0/16` | `10.51.0.0/16` | `172.19.255.192/26` |
| `eg2` | `172.19.0.4` / `172.19.0.5` | `10.60.0.0/16` | `10.61.0.0/16` | `172.19.255.128/26` |

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `kind-eg` IPv4 | `172.19.0.0/16` (`ip-range` `/17`, gateway `.1`) | the lab bridge | Docker IPAM (nodes only) |
| reserved VIP `/24` | `172.19.255.0/24` | never a node address | — |
| `eg1` `/26` | `172.19.255.192/26` | services `.200–.239`; gateways `.240–.250` | demo 51 / 52 |
| `eg2` `/26` | `172.19.255.128/26` | services `.136–.175`; gateways `.176–.186` | demo 51 / 52 |
| shared `/26` | `172.19.255.0/26` | product VIP `.16` / `.17` | demo 51 / 52 |
| `eg-poc1` `/26` | `172.19.255.64/26` | one-cluster lab | demo 54 |

## Prerequisites

- docker, kind `v0.33.0`, and helm on the `PATH`.
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  Gateway API `v1.6.2`, Envoy Gateway `v1.9.1`, cert-manager `v1.21.1`,
  node image
  `kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`.
- A route on the Mac to the lab bridge (recorded:
  `172.19  192.168.64.2  UGSc  bridge100`):

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

poc1 and poc2 stay paused. The `kind` network is not touched.

## Steps

Do these in order from the repo root (`eg-up.sh` runs all eight; `eg1` is
always first so the root exists before any copy):

### 1. Create the network

`kind-eg` is a second instance of the reservation the Cilium lab already
uses on `kind`.

```bash
scripts/eg-net.sh
docker network inspect kind-eg --format \
  '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'
```

Result: IPv4 `subnet=172.19.0.0/16 ip-range=172.19.0.0/17
gateway=172.19.0.1`; IPv6 ULA `fc00:f853:ccd:e794::/64` (inspect prints
`ip-range=invalid Prefix` on that block).

```text
exists with 172.19.0.0/16, kept
subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1
subnet=fc00:f853:ccd:e794::/64 ip-range=invalid Prefix gateway=fc00:f853:ccd:e794::1
```

### 2. Create the clusters

Stock networking: kindnet and kube-proxy, mode `iptables`, no Cilium
([enhancement 007](../../enhancements/007-envoy-gateway-lab.md) R2). The
configs are [`clusters/eg1.yaml`](../../clusters/eg1.yaml) and
[`clusters/eg2.yaml`](../../clusters/eg2.yaml).

```bash
env KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg kind create cluster \
  --config clusters/eg1.yaml \
  --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
env KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg kind create cluster \
  --config clusters/eg2.yaml \
  --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
```

Result: `eg1` Ready at `172.19.0.2` / `172.19.0.3`; `eg2` Ready at
`172.19.0.4` / `172.19.0.5`; kindnet and kube-proxy `2/2`;
`mode: iptables`.

```text
eg1-control-plane 172.19.0.2
eg1-worker 172.19.0.3
eg2-control-plane 172.19.0.4
eg2-worker 172.19.0.5
    mode: iptables
```

### 3. Install the Gateway API standard CRDs

Upstream's `standard-install.yaml` v1.6.2, applied server-side, so a
rerun does not fight an older field manager (D5, D10). The channel
assertion fails the script if either annotation drifts.

```bash
kubectl --context kind-eg1 apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
kubectl --context kind-eg2 apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
```

Result: `gateway.networking.k8s.io CRDs: 10 (want 10)`; every CRD
`channel=standard bundle-version=v1.6.2` on both clusters.

```text
gateway.networking.k8s.io CRDs: 10 (want 10)
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
```

### 4. Install Envoy Gateway's CRDs

The vendor-prescribed pipe
([install-helm](https://gateway.envoyproxy.io/docs/install/install-helm/)):
`gateway-crds-helm` v1.9.1 with Gateway API left off, rendered and
applied server-side. A Helm release of that chart cannot store its
Secret (see *Troubleshooting*).

```bash
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl --context kind-eg1 apply --server-side --force-conflicts -f -
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl --context kind-eg2 apply --server-side --force-conflicts -f -
```

Result: `gateway.envoyproxy.io CRDs: 8 (want 8)` on both clusters.

```text
gateway.envoyproxy.io CRDs: 8 (want 8)
customresourcedefinition.apiextensions.k8s.io/backends.gateway.envoyproxy.io
customresourcedefinition.apiextensions.k8s.io/securitypolicies.gateway.envoyproxy.io
```

### 5. Install the Envoy Gateway controller

`gateway-helm` v1.9.1 with `crds.enabled=false` — its one switch is
all-or-nothing, so it is told the CRDs are already there.

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 -n envoy-gateway-system --create-namespace \
  --kube-context kind-eg1 --set crds.enabled=false
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 -n envoy-gateway-system --create-namespace \
  --kube-context kind-eg2 --set crds.enabled=false
```

Result: release `eg` `STATUS: deployed`;
`deployment "envoy-gateway" successfully rolled out` on both.

```text
NAME: eg
NAMESPACE: envoy-gateway-system
STATUS: deployed
deployment "envoy-gateway" successfully rolled out
```

### 6. Create the GatewayClass

The chart does not create `GatewayClass eg`
([`clusters/eg/gatewayclass.yaml`](../../clusters/eg/gatewayclass.yaml);
controller `gateway.envoyproxy.io/gatewayclass-controller`).

```bash
kubectl --context kind-eg1 apply -f clusters/eg/gatewayclass.yaml
kubectl --context kind-eg1 wait --for=condition=Accepted gatewayclass/eg --timeout=60s
kubectl --context kind-eg2 apply -f clusters/eg/gatewayclass.yaml
kubectl --context kind-eg2 wait --for=condition=Accepted gatewayclass/eg --timeout=60s
```

Result: `gatewayclass.gateway.networking.k8s.io/eg condition met` on
both; final table `Accepted=True`.

```text
gatewayclass.gateway.networking.k8s.io/eg condition met
```

### 7. Install cert-manager and the lab root

cert-manager v1.21.1 with `crds.enabled=true`. `eg1` applies
[`clusters/eg/eg-root-ca.yaml`](../../clusters/eg/eg-root-ca.yaml)
(Issuer + CA Certificate `CN=eg-root-ca`, isCA, 87600h, + ClusterIssuer).
`eg2` receives the Secret via a server-side apply and
[`clusters/eg/eg-ca-issuer.yaml`](../../clusters/eg/eg-ca-issuer.yaml)
only (D8).

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.1 --namespace cert-manager --create-namespace \
  --kube-context kind-eg1 --set crds.enabled=true --wait --timeout 5m
kubectl --context kind-eg1 apply -f clusters/eg/eg-root-ca.yaml
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.1 --namespace cert-manager --create-namespace \
  --kube-context kind-eg2 --set crds.enabled=true --wait --timeout 5m
```

Result: `cert-manager v1.21.1 has been deployed successfully!`;
Certificate and ClusterIssuer Ready on `eg1`;
`secret/eg-root-ca serverside-applied` on `eg2`; ClusterIssuer Ready
there too.

```text
cert-manager v1.21.1 has been deployed successfully!
certificate.cert-manager.io/eg-root-ca condition met
clusterissuer.cert-manager.io/eg-ca-issuer condition met
secret/eg-root-ca serverside-applied
```

### 8. Export the root

The PEM is written under `.tmp/` and gitignored — issue #60: a committed
copy is a different certificate after every rebuild.

```bash
kubectl --context kind-eg1 -n cert-manager get secret eg-root-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > .tmp/eg-root-ca.crt
openssl x509 -in .tmp/eg-root-ca.crt -noout -subject -issuer -fingerprint -sha256
```

Result: `subject=CN=eg-root-ca`, `issuer=CN=eg-root-ca`, the fingerprint
below on both clusters.

```text
subject=CN=eg-root-ca
issuer=CN=eg-root-ca
sha256 Fingerprint=6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
CLUSTER  NODES/IPs                                        KUBEPROXY  GW_API       EG_CRDS  GATEWAYCLASS ENVOY-GATEWAY  CERT-MANAGER   ROOT_SHA256
eg1      eg1-control-plane=172.19.0.2 eg1-worker=172.19.0.3  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
eg2      eg2-control-plane=172.19.0.4 eg2-worker=172.19.0.5  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
```

## Verify

Confirm the reservation, the CRD counts, then the recorded check:

```bash
docker network inspect kind-eg --format \
  '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'
```

```text
subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1
subnet=fc00:f853:ccd:e794::/64 ip-range=invalid Prefix gateway=fc00:f853:ccd:e794::1
```

```bash
kubectl --context kind-eg1 get crd -o name | grep -c '\.gateway\.networking\.k8s\.io$'
kubectl --context kind-eg1 get crd -o name | grep -c '\.gateway\.envoyproxy\.io$'
```

```text
gateway.networking.k8s.io CRDs: 10 (want 10)
gateway.envoyproxy.io CRDs: 8 (want 8)
```

```bash
demos/50-eg-clusters/check.sh
```

Recorded `2026-09-18T23:15:58Z`: 27 PASS, 0 FAIL.

```text
== demo 50 — the vanilla lab's clusters (enhancement 007 phase 1)
demo 50 check: 0 FAIL
```

## Reference

| Pin | Value |
|---|---|
| Gateway API | `v1.6.2` (`standard-install.yaml`, channel `standard`) |
| Envoy Gateway | `v1.9.1` (`gateway-crds-helm` + `gateway-helm`, `crds.enabled=false`) |
| cert-manager | `v1.21.1` |
| kind | `v0.33.0` |
| node image | `kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed` |

Address plan ([enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md)):

| Block | Owner | What it holds | Announced by |
|---|---|---|---|
| `172.19.0.0/17` | Docker | node addresses (`--ip-range`) | — |
| `172.19.255.0/24` | the lab | reserved VIP `/24`, never a node | — |
| `172.19.255.192/26` | **eg1** | services `.200–.239`; gateways `.240–.250` | demo 51 / 52 |
| `172.19.255.128/26` | **eg2** | services `.136–.175`; gateways `.176–.186` | demo 51 / 52 |
| `172.19.255.0/26` | shared | product VIP `.16` (kube-vip) and `.17` (MetalLB) | demo 51 / 52 |
| `172.19.255.64/26` | **eg-poc1** | services `.72–.79`; gateways `.100–.110` | demo 54 |
| `172.19.254.0/24` | reserved | network devices, if enhancement 006 peers later | — |

| File | What |
|---|---|
| [`scripts/eg-up.sh`](../../scripts/eg-up.sh) | network, both clusters, the three-command install, GatewayClass, cert-manager, the root |
| [`scripts/eg-down.sh`](../../scripts/eg-down.sh) | deletes `eg1`, `eg2`, `eg-poc1`, and `kind-eg` only |
| [`scripts/eg-net.sh`](../../scripts/eg-net.sh) | the `kind-eg` bridge |
| [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env) | the pins |
| [`clusters/eg1.yaml`](../../clusters/eg1.yaml) / [`eg2.yaml`](../../clusters/eg2.yaml) | kind configs (kindnet + kube-proxy iptables; pods `10.50/16` / `10.60/16`) |
| [`clusters/eg/gatewayclass.yaml`](../../clusters/eg/gatewayclass.yaml) | `GatewayClass eg` |
| [`clusters/eg/eg-root-ca.yaml`](../../clusters/eg/eg-root-ca.yaml) | Issuer + CA Certificate + ClusterIssuer, applied on `eg1` |
| [`clusters/eg/eg-ca-issuer.yaml`](../../clusters/eg/eg-ca-issuer.yaml) | ClusterIssuer only, applied on `eg2` after the Secret is copied |
| [`check.sh`](check.sh) | 27 PASS/FAIL rows; exit = FAIL count |

Root: `subject=CN=eg-root-ca`, `issuer=CN=eg-root-ca`, isCA, 87600h,
Secret `cert-manager/eg-root-ca`. Fingerprint
`6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16`.
PEM: `.tmp/eg-root-ca.crt` (gitignored; issue #60).

## Troubleshooting

- Every client on the Mac times out while the clusters are Ready: the
  `172.19` route is missing (it does not survive a reboot) —
  [gotcha #120](../../docs/GOTCHAS.md#120); add it with the command
  under *Prerequisites*.
- A Helm install of the CRD chart fails with this line; the method is
  the vendor-prescribed pipe under step 4
  ([helm/helm#12277](https://github.com/helm/helm/issues/12277)):

```text
Error: create: failed to create: Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long: may not be more than 1048576 bytes
```

- `eg2` built alone dies if `eg1` has no Secret: one root, minted on
  `eg1`. Run `eg1` first (or both, default):

```bash
scripts/eg-up.sh
```

## Clean up

```bash
scripts/eg-down.sh
```

Deletes `eg1`, `eg2`, `eg-poc1`, and `kind-eg`. Does not touch poc1,
poc2, CRC, or the `kind` network.

## What's next

- [Demo 51](../51-eg-kube-vip/README.md) installs kube-vip on these
  clusters and creates the Gateways.
- [Demo 54](../54-eg-poc1-kube-vip/README.md) is the one-cluster lab:
  kube-vip and two doors that isolate HTTP from gRPC.
