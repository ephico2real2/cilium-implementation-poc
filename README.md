# cilium-kind-poc

A reproducible, local proof-of-concept that demonstrates what **Cilium** and **Hubble** give you
over a stock CNI + kube-proxy Kubernetes cluster — built on [kind](https://kind.sigs.k8s.io/), on a
laptop, from nothing.

Every command is documented one at a time in **[docs/SETUP.md](docs/SETUP.md)**, written for someone
who has not done this before: what each command does, its real captured output, and how to tell it
worked. Where something went wrong during the build, the failure and the diagnosis are kept in the
guide rather than tidied away — the debugging is the useful part.

## What it builds

| Cluster | Nodes | Pod CIDR | Service CIDR | Cilium cluster id |
|---|---|---|---|---|
| `poc1` | 3 control-plane + 2 worker | `10.10.0.0/16` | `10.11.0.0/16` | 1 |
| `poc2` | 1 control-plane + 1 worker | `10.20.0.0/16` | `10.21.0.0/16` | 2 |

`poc1` is the main cluster — three control planes so etcd keeps a real majority and a control-plane
failure can actually be demonstrated. `poc2` exists to be the far side of the ClusterMesh demo, so
it is deliberately minimal. The CIDRs do not overlap because ClusterMesh requires it.

Both clusters run with **no kube-proxy** (`kubeProxyMode: none`) and **no default CNI**
(`disableDefaultCNI: true`) — Cilium is both.

## Versions this was built and verified against

| Component | Version |
|---|---|
| kind | 0.33.0 |
| Kubernetes (node image) | v1.36.4, pinned by digest |
| Cilium | 1.20.1 |
| cilium CLI | v0.20.0 |
| Hubble CLI | 1.19.4 |

**The Kubernetes version is not the default and that is deliberate.** kind 0.33.0 defaults to
v1.37.0, but Cilium 1.20.1 is e2e-tested only on 1.33–1.36. Taking the default would put the PoC on
an untested combination.

## Demos

| # | Demo | What it proves |
|---|---|---|
| 01 | Hubble flows + UI | Per-flow, identity-aware visibility that iptables cannot produce |
| 02 | L7 HTTP policy | Allow `POST /v1/request-landing`, deny `PUT /v1/exhaust-port` between the *same* two pods — inexpressible in iptables |
| 03 | kube-proxy free | Services load-balanced in eBPF; no kube-proxy DaemonSet exists at all |
| 04 | WireGuard | Node-to-node encryption from one helm value |
| 05 | Gateway API | Cilium as the Gateway controller, address from Cilium's own LB IPAM |
| 06 | Performance | Bandwidth manager + BBR, BIG TCP, measured with iperf3 |
| 07 | ClusterMesh | A global Service backed by pods in a second cluster, with failover |

## Status

Build in progress. See `docs/SETUP.md` for what is verified so far and `docs/FINDINGS.md` for
measured results.
