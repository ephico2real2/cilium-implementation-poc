# What demo 50 did — the walk-through

**The goal.** Enhancement 007 builds a second lab next to the Cilium one: two kind
clusters, stock networking (kindnet and kube-proxy in iptables mode), the
Gateway API CRDs from the standard channel, and Envoy Gateway as the
implementation — so that demos 51 and 52 can put kube-vip and MetalLB in
front of the same doors and show what Cilium had bundled. Demo 50 is phase 1:
the clusters and the CRDs. Think of it as pouring the slab and standing up the
controller before anyone hangs a door on it.

**1. The operator asked to tear the first cluster down and build both from the guide.**
Phase 0 had created eg1 by hand and left probes, kube-vip and MetalLB on it.
`scripts/eg-down.sh` had only been syntax-checked. At 22:41:16Z it deleted
`eg1-worker` and `eg1-control-plane`, then removed the `kind-eg` network.
poc1 and poc2 stayed `Exited (137)` on the `kind` network; that network was
not touched. Nothing from phase 0's hand-applied objects survived except what
the new script applies again.

**2. The reservation trick is the same idea as the Cilium lab, on a second bridge.**
`scripts/eg-net.sh` created `kind-eg` at `172.19.0.0/16` with Docker's
allocation held to `172.19.0.0/17` and gateway `172.19.0.1`. The IPv6 ULA is
`fc00:f853:ccd:e794::/64`, chosen adjacent to the `kind` bridge's
`…e793::/64` so the two cannot share a subnet. Node addresses therefore cannot
land in the reserved VIP `/24` at `172.19.255.0/24` — that block is for demos
51 and 52. Docker inspect prints `ip-range=invalid Prefix` on the IPv6 block
because no IPv6 `--ip-range` was set; the check reads the IPv4 block only.

**3. Both clusters came up on that bridge with stock networking.**
`KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg` still prints "Here be dragons".
eg1's nodes are `172.19.0.2` and `172.19.0.3`; eg2's are `172.19.0.4` and
`172.19.0.5`. kindnet and kube-proxy are 2/2 on both; kube-proxy's ConfigMap
says `mode: iptables`; `kubectl get ds -A | grep -c cilium` is 0. That is the
vanilla stack: a CNI that is not Cilium, a kube-proxy that is still there.

**4. "Installing Envoy Gateway" is three commands, and the middle one cannot be a Helm release.**
The Gateway API CRDs come from upstream's `standard-install.yaml` v1.6.2,
applied server-side so a rerun does not fight an older field manager. All ten
CRDs are annotated `channel: standard` and `bundle-version: v1.6.2` — the
check fails if either annotation drifts (D10). Envoy Gateway's own eight CRDs
were supposed to be a Helm release (`gateway-crds-helm`, Gateway API left
off). Helm refused: `Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data:
Too long: may not be more than 1048576 bytes`. The guide fell back to phase
0's `helm template | kubectl apply --server-side` and recorded why. The
controller chart installs as release `eg` with `crds.enabled=false` — its only
switch is all-or-nothing, so it must be told the CRDs are already there. The
chart does not create `GatewayClass eg`; that is a separate apply, Accepted on
both clusters.

**5. The lab has its own root, and it is not committed.**
cert-manager v1.21.1 (the Cilium lab's pin) is installed with
`crds.enabled=true`, the same Helm form as `lab-up.sh`. eg1 mints a
self-signed CA `eg-root-ca` (CN `eg-root-ca`, isCA, ten years); the Secret is
copied to eg2; `ClusterIssuer/eg-ca-issuer` is Ready in both. The SHA-256
fingerprint
`6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16`
is identical on both sides. The PEM is written to `.tmp/eg-root-ca.crt` and
gitignored — issue #60 showed a committed root is a different certificate
after every rebuild. This is not the Cilium lab's `clustermesh-root-ca`; a
client that uses both labs trusts two files.

**6. The doors are not here on purpose.**
No load balancer, no Gateway, no app. The reserved `/24` is empty. Demo 51
hangs kube-vip on these clusters and creates the Gateways with the
`EnvoyProxy` already attached (the class is immutable — phase 0 measured
that). Demo 52 does the same with MetalLB. `check.sh` is 27 PASS, 0 FAIL.

**The reference card — names, addresses, certificates, doors.** Read from the
live objects and [`output/transcript.txt`](output/transcript.txt). There are
no Gateways yet; the picture is the two clusters on the bridge and the blocks
they will announce from.

*The network blocks ([enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md)).*

| Block | Owner | What it holds | Announced by |
|---|---|---|---|
| `172.19.0.0/17` | Docker | node addresses (`--ip-range`) — eg1 `.2`/`.3`, eg2 `.4`/`.5` today | — |
| `172.19.255.0/24` | the lab | the reserved VIP `/24`, never a node | — |
| `172.19.255.192/26` | **eg1** | services `.200–.239`; gateways `.240–.250` | demo 51 / 52 |
| `172.19.255.128/26` | **eg2** | services `.136–.175`; gateways `.176–.186` | demo 51 / 52 |
| `172.19.255.0/26` | shared | product VIP `.16` (kube-vip) and `.17` (MetalLB) | demo 51 / 52 |
| `172.19.254.0/24` | reserved | network devices, if enhancement 006 peers later | — |

*The CRD sets.*

| Set | Count | Channel / source | Helm release? |
|---|---|---|---|
| `gateway.networking.k8s.io` | 10 | `channel: standard`, `bundle-version: v1.6.2`, from `standard-install.yaml` | no — `kubectl apply --server-side` |
| `gateway.envoyproxy.io` | 8 | `gateway-crds-helm` with `crds.gatewayAPI.enabled=false` | no — Helm Secret would exceed 1 MiB |
| Envoy Gateway controller | — | `gateway-helm` `crds.enabled=false` | **yes** — release `eg` |
| Gateway API from the CRD chart with `gatewayAPI.enabled=true` | 10 + mix | **13 × experimental, 2 × standard** (phase 0 render) | not installed |

*The root.* One CA, minted on eg1, copied to eg2. Not a leaf, not per cluster.

```yaml
kind: Certificate                   # cert-manager.io/v1, namespace cert-manager, eg1 only
spec:
  isCA: true
  commonName: eg-root-ca
  duration: 87600h                  # 10 years
  secretName: eg-root-ca            # copied to eg2; ClusterIssuer/eg-ca-issuer in both
  issuerRef: {kind: Issuer, name: selfsigned-bootstrap}
```

Issued certificate: `subject=CN=eg-root-ca`, `issuer=CN=eg-root-ca`, valid ten
years from 2026-09-18, fingerprint above. Export: `.tmp/eg-root-ca.crt`. The
Mac's route `172.19 → 192.168.64.2` on `bridge100` is present; no script adds
it.

```text
                         Mac  ── route 172.19/16 → 192.168.64.2 ──  Docker VM
                                                                    │
                         docker network kind-eg   172.19.0.0/16
                         Docker allocates from 172.19.0.0/17 only
                         IPv6 ULA fc00:f853:ccd:e794::/64
                                    │
              ┌─────────────────────┴──────────────────────┐
              │  eg1                    │  eg2             │
              │  .0.2 control-plane     │  .0.4 cp         │
              │  .0.3 worker            │  .0.5 worker     │
              │  pods 10.50/16          │  pods 10.60/16   │
              │  svc  10.51/16          │  svc  10.61/16   │
              │  kindnet + kube-proxy   │  same            │
              │  GatewayClass eg        │  GatewayClass eg │
              │  envoy-gateway 1/1      │  envoy-gateway   │
              │  cert-manager + root    │  same Secret     │
              │                         │                  │
              │  reserved .192/26       │  reserved .128/26│
              │  (empty — demo 51/52)   │  (empty)         │
              └─────────────────────────┴──────────────────┘
                         reserved .0/26 shared VIP  (empty)
```

**What the review caught.** The review pass has not run (PR #62 is still
open). One implementation catch changed the check: `docker network inspect`
prints `invalid Prefix` for the IPv6 `IPRange`, so concatenating every
`.IPRange` looked like `172.19.0.0/17invalid Prefix` and failed a correct
network. The check now reads the IPv4 block only.

**What you can do with it right now.**

- `kubectl --context kind-eg1 get nodes -o wide` — `.2` and `.3` inside the
  lower `/17`.
- `helm list -n envoy-gateway-system --kube-context kind-eg1` — release `eg`
  only.
- `kubectl --context kind-eg1 get gatewayclass` — `eg` Accepted.
- `demos/50-eg-clusters/check.sh` — the 27 checks.

**Where the next demo starts.** Demo 51 installs kube-vip with the three class
filters phase 0 measured, and creates the first Gateways with an `EnvoyProxy`
that already carries `loadBalancerClass` — the field that cannot be patched
on later. Demo 52 repeats the doors on MetalLB. Both reuse these clusters,
this class, and this root.
