# FINDINGS — measured results

Everything here was captured on the build machine. Nothing is estimated or reproduced from
documentation. Where a claim could not be measured, it says so.

Build machine: macOS Darwin 24.6.0, x86_64, 16 CPU / 32 GB host; Docker Desktop VM 15.62 GB,
kernel `6.6.12-linuxkit`. Cluster `poc1`: kind 0.33.0, Kubernetes v1.36.4, Cilium 1.20.1.

## Environment constraints discovered

| Finding | Value | Consequence |
|---|---|---|
| Docker VM memory (default) | 7.66 GB | Too small for 7 nodes; raised to 15.62 GB |
| Docker VM kernel | `6.6.12-linuxkit` | **netkit unavailable** (needs ≥6.7); demo 06 uses bandwidth manager + BIG TCP instead |
| kind default node image | v1.37.0 | **Not used.** Cilium 1.20.1 is e2e-tested on 1.33–1.36 only; pinned v1.36.4 by digest |
| kind external load balancer | `envoyproxy/envoy:v1.36.2` | Envoy, not HAProxy as older guides say |
| Hubble CLI vs Relay | 1.19.4 vs 1.20.1 | Version warning on every command. `cilium/hubble`'s newest release *is* 1.19.4, so no matching CLI exists; warning is expected, not a misconfiguration |

## Cluster and Cilium state

```
$ kubectl get nodes
poc1-control-plane    Ready    control-plane   v1.36.4
poc1-control-plane2   Ready    control-plane   v1.36.4
poc1-control-plane3   Ready    control-plane   v1.36.4
poc1-worker           Ready    <none>          v1.36.4
poc1-worker2          Ready    <none>          v1.36.4
```

```
$ cilium status
Cilium:             OK      DaemonSet cilium          5/5
Operator:           OK      Deployment cilium-operator 1/1
Envoy DaemonSet:    OK      DaemonSet cilium-envoy    5/5
Hubble Relay:       OK      Deployment hubble-relay   1/1
ClusterMesh:        disabled
```

```
$ cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading'
KubeProxyReplacement:    True   [eth0 172.18.0.4 ... (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]
```

## Demo 03 — kube-proxy replacement

Measured **before** Cilium was installed, which is what makes the claim honest:

```
$ kubectl -n kube-system get daemonset
No resources found in kube-system namespace.
```

There was never a kube-proxy DaemonSet to replace — `kubeProxyMode: none` in the kind config meant
it was never installed. Combined with `KubeProxyReplacement: True` above and a working ClusterIP
Service in demo 02, services are demonstrably being load-balanced by eBPF and by nothing else.

## Demo 01 — Hubble observability

```
$ hubble status -P
Healthcheck (via 127.0.0.1:4245): Ok
Current/Max Flows: 19,311/20,475 (94.32%)
Flows/s: 27.68
Connected Nodes: 5/5
```

Flows carry pod names, numeric security identities, verdicts and L7 detail — see demo 02 stage 3.

## Demo 02 — L3/L4 vs L7 policy

| Stage | Client | Request | Result |
|---|---|---|---|
| No policy | tiefighter | `POST /v1/request-landing` | `Ship landed` |
| No policy | xwing | `POST /v1/request-landing` | `Ship landed` |
| L3/L4 | tiefighter | `POST /v1/request-landing` | `Ship landed` |
| L3/L4 | xwing | `POST /v1/request-landing` | **timeout, curl exit 28** |
| L3/L4 | tiefighter | `PUT /v1/exhaust-port` | **`Panic: deathstar exploded`** — the gap |
| L7 | tiefighter | `POST /v1/request-landing` | `Ship landed`, HTTP 200 in 3 ms |
| L7 | tiefighter | `PUT /v1/exhaust-port` | **`Access denied`, HTTP 403 in 16.9 ms** |
| L7 | xwing | `POST /v1/request-landing` | still timeout (denied at L3) |

The headline number is the pair on the last two rows of the L7 block: **the same pod, the same
destination, the same TCP port, and two different verdicts decided by HTTP method and path.**

Secondary observation, useful as a diagnostic: an L3/L4 denial presents as a **timeout** (the SYN is
dropped), an L7 denial as an **immediate 403** (Envoy accepted, parsed, refused).

## Still to measure

- Demo 04 WireGuard — encryption status and on-the-wire capture
- Demo 05 Gateway API — Gateway address from Cilium LB IPAM, HTTPRoute behaviour
- Demo 06 performance — iperf3 pod-to-pod before/after bandwidth manager + BBR (netkit excluded)
- Demo 07 ClusterMesh — global service failover across poc1/poc2
- `cilium connectivity test` full run
