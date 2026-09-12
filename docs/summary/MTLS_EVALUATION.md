# Evaluation — "Cilium mTLS": what exists, what is on, what to do (2026-09-11)

**Short answer.** Nothing mTLS-shaped is enabled on poc1 or poc2, and the feature that Cilium has
called "mutual authentication" since 1.14 is **deprecated as of 1.20 and slated for removal in
1.21**. Its named successor — `ztunnel`, Istio's ambient-mode L4 proxy, driven by Cilium as an
encryption type — ships **beta** in the 1.20.1 chart we run. Recommendation at the end.

## 1. Measured state (poc1, Cilium 1.20.1)

```
$ helm get values cilium -n kube-system --kube-context kind-poc1 | grep -A4 '^authentication'
(nothing — chart default)
$ kubectl -n kube-system get cm cilium-config -o json | … 'auth' keys
  mesh-auth-enabled = false
  mesh-auth-gc-interval = 5m0s
  mesh-auth-queue-size = 1024
  mesh-auth-rotated-identities-queue-size = 1024
$ kubectl get pods -A | grep -ci spire            -> 0
$ policies with authentication.mode (CNP + CCNP)  -> 0
$ cilium-dbg status --verbose | grep -i auth      -> "Auth  524288"   (the BPF auth map exists, sized, empty)
```

Also relevant: `encryption.enabled: false` in both values files (demo 04 proved WireGuard and
switched it off), so pod-to-pod traffic is **neither authenticated beyond Cilium identities nor
encrypted** today. That is the documented, deliberate state of this PoC.

## 2. What Cilium "mutual authentication" is — and is not

From the docs ([Mutual Authentication](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/)):

- Identities are **SPIFFE** IDs (`spiffe://trust.domain/…`) issued by a **SPIRE** server (root of
  trust) through per-node SPIRE agents; the Cilium agent requests SVIDs on workloads' behalf.
- A network policy opts a flow in with `authentication.mode: required`; the first packet triggers
  an **out-of-band** TLS handshake between the two *agents*, the result is cached in the BPF auth
  map, and the data path is then allowed — *"brings the mutual authentication handshake
  out-of-band for regular connections"*.
- It does **not encrypt traffic**. The chart says so where it counts: *"Note that this is not
  full mTLS support without also enabling encryption of some form. Current encryption options are
  WireGuard or IPsec."* So "Cilium mTLS" was always **identity handshake (SPIFFE) + WireGuard/IPsec
  encryption**, two features.
- Beta since 2023; *"not compatible with Cluster Mesh"*; validated only with SPIRE.

## 3. The deprecation — verified at the source

The 1.20.1 chart values, under `authentication.mutual`:

> *Deprecated as of Cilium v1.20, this feature will be removed in Cilium v1.21. See
> https://github.com/cilium/cilium/issues/47132 for details.*

[cilium/cilium#47132](https://github.com/cilium/cilium/issues/47132) (open, `kind/cfp`,
"Mutual Auth Deprecation and Removal"), verbatim:

> *It's been in Beta since then, with an outstanding improvement issue, that hasn't seen any
> movement from the community … Given the lack of progress on Mutual Auth, and the presence and at
> least equal stability of the new feature, as of Cilium v1.20, Cilium committers are marking the
> Mutual Auth feature as deprecated, and will remove the feature in a later version, most likely
> v1.21. … this decision is not up for debate without clear proof of ongoing commitment.*

Building a demo, a policy set, or an enterprise design on it now would be building on a feature
with a removal date.

## 4. The successor — `ztunnel` as an encryption type (beta in 1.20)

[cilium/cilium#38548](https://github.com/cilium/cilium/issues/38548) ("Add support for ztunnel",
open, pinned): *"ztunnel is an implementation of HBONE which provides L4 proxying … through an
mTLS HTTP/2 tunnel … Add `ztunnel` as an alternative datapath encryption mechanism to provide
pod-to-pod encryption with mutual authentication (mTLS)."* — i.e. **one feature that is both**
the identity and the encryption, which is what people mean by mTLS.

It is in the chart we run (`helm show values cilium/cilium --version 1.20.1`):

```yaml
encryption:
  enabled: false
  type: ipsec            # "Can be one of ipsec, wireguard or ztunnel."
  ztunnel:               # "These settings only apply when encryption.type is set to "ztunnel"."
    ca:
      type: internal     # enum: [spire, internal] — "internal" uses Cilium's built-in CA, no SPIRE needed
    image: quay.io/cilium/ztunnel:v1.0.0   (pinned by digest)
```

Facts we do **not** yet have, and would need to measure before adopting: whether it coexists with
ClusterMesh (mutual auth did not), its throughput cost versus WireGuard on this VM (demo 04
measured WireGuard at roughly half of plaintext), how it interacts with the Gateway (Envoy) path,
and that Hubble shows the HBONE sessions (the CFP lists this as a task). There is no docs page for
it yet at `docs.cilium.io/en/stable/network/servicemesh/ztunnel/` (404 on 2026-09-11); the chart
comments are the documentation.

## 5. Options, honestly

| Option | What you get | Cost / risk | Verdict |
|---|---|---|---|
| **A. Stay as is** — Cilium identities + policy, no encryption | identity-aware L3–L7 policy (demos 02, 05, 09); nothing on the wire is protected | none | the current documented state |
| **B. WireGuard on** (`encryption.type=wireguard`) | encryption + node-level authentication of *nodes* (keys), not of *workloads* | demo 04 measured ~50 % throughput on this VM; one helm value | the proven, supported answer to "encrypt pod traffic" — for **workload** identity it is not mTLS |
| **C. Mutual auth (SPIFFE/SPIRE) + WireGuard** | the thing Cilium called mTLS | deprecated in 1.20, gone in 1.21; ClusterMesh-incompatible; SPIRE to run | **do not build on it** |
| **D. `encryption.type=ztunnel`** | mTLS proper (HBONE, per-workload identity, encryption) with Cilium's internal CA | beta; agent restart (gotcha #42); mesh/Gateway/Hubble interactions unmeasured | **the one to evaluate** — as a demo on poc1 with poc2 paused, restore from a values snapshot as in demo 11 |

## 6. Recommendation — now measured (demo 13, 2026-09-12)

The ztunnel exercise was run: on poc1 it **cannot start at all** (`cluster.id 1` — the agent
refuses any non-zero id, gotcha #45), so it ran on a throwaway `poc4` with `cluster.id 0`. There
it is real mTLS (HBONE :15008, request marker unreadable on the wire, TLS handshake captured) — and
it **drops every Cilium network policy on enrolled traffic**: an L4 policy denied the *allowed*
peer (`Policy denied` on :15008), an L7 policy returned 000/000/000 where 200/403/403 was expected.
Throughput 1,216 vs 4,536 Mbit/s, same pods, enrollment toggled. Full write-up:
`demos/13-ztunnel/README.md`.

**Decision: not the production standard.** The standard for this design is identity-based policy
(demos 02/05/09) plus **WireGuard** where encryption is required (demo 04, GA, coexists with policy
and the mesh, ~50 % cost). Re-evaluate ztunnel at GA, when it is policy-aware and cluster-id
agnostic. The paragraph below is the pre-measurement plan, kept for the record.

### 6a. The plan as written before the run

Do not enable mutual authentication. Evaluate **ztunnel** as parked demo 13, the same forensic
way demo 11 was done: snapshot the release values; `--set encryption.enabled=true
--set encryption.type=ztunnel` (internal CA); prove it (a Hubble flow showing the HBONE tunnel, a
capture on `eth0` showing ciphertext as demo 04 did, `cilium status` encryption line); measure
throughput and churn with `scripts/forensic.sh`; test the Gateway path and ClusterMesh; restore.
Until then, the honest sentence for the network/security team is: *"Cilium gives us identity-based
policy today, WireGuard for encryption when we want it, and mTLS proper is a beta we have not yet
measured; the older 'mutual authentication' feature is being removed and we will not adopt it."*

## 7. Are we on the latest Cilium? Yes

Checked 2026-09-11: newest chart in the `cilium` helm repo **1.20.1**; newest non-prerelease
upstream tag **v1.20.1**; running `quay.io/cilium/cilium:v1.20.1` on both clusters; cilium-cli
v0.20.0. The 1.20 release ([v1.20.0, 2025-07-29](https://github.com/cilium/cilium/releases/tag/v1.20.0);
[Isovalent's post](https://isovalent.com/blog/post/cilium-1-20/)) headlines Gateway API v1.6.1
(ExternalAuth, TCPRoute/UDPRoute, BackendTLS — demo 09 uses the CRDs), better BGP tooling (parked
demo 12), and automatic netkit selection on supported kernels (not this one, demo 06).
