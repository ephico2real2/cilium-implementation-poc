# Demo 03 — Services without kube-proxy

## Summary context

**What this demo is about.** In a stock Kubernetes cluster, `kube-proxy` runs as a DaemonSet on
every node and implements Services by programming **iptables** (or IPVS) rules. Every ClusterIP is a
chain of NAT rules; every backend pod is another rule. It works, and it has two well-known costs:
the ruleset is evaluated linearly so it degrades as services grow, and a whole update is rewritten
when endpoints change.

Cilium implements the same Service semantics in **eBPF** — a hash-table lookup in the kernel
datapath instead of a rule chain — and can therefore replace kube-proxy entirely.

**What makes this PoC's version of the claim honest.** It is easy to *say* kube-proxy was replaced.
Here, kube-proxy was **never installed at all**: `clusters/poc1.yaml` sets `kubeProxyMode: none`, so
kubeadm skips the addon. There is nothing running alongside Cilium that could quietly be doing the
work. The evidence below is in three parts — kube-proxy is absent, Cilium says it is handling
services, and services demonstrably work.

**Prerequisite:** cluster `poc1` up with Cilium installed (SETUP.md Steps 3–6), and the demo 02 app
deployed (it provides the `deathstar` Service used at the end).

All output below is in [`output/transcript.txt`](output/transcript.txt), captured with
`scripts/record.sh`.

---

## Part 1 — kube-proxy does not exist

```bash
scripts/record.sh demos/03-kube-proxy-free/output/transcript.txt \
  kubectl --context kind-poc1 -n kube-system get daemonset
```

```
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
cilium         5         5         5       5            5           kubernetes.io/os=linux   40m
cilium-envoy   5         5         5       5            5           kubernetes.io/os=linux   40m
```

Two DaemonSets, both Cilium's. No `kube-proxy`.

```bash
kubectl --context kind-poc1 -n kube-system get pods -l k8s-app=kube-proxy
```

```
No resources found in kube-system namespace.
```

**Before Cilium was even installed**, the same query returned `No resources found in kube-system
namespace.` for *all* DaemonSets — captured in SETUP.md Step 3. That is the strongest form of the
claim: the slot was empty before Cilium arrived, so nothing was displaced or left running.

## Part 2 — the iptables ruleset is empty of Services

This is the part people find most convincing, because it inspects the mechanism kube-proxy would
have used rather than taking anyone's word for it.

```bash
docker exec poc1-worker iptables-save | grep -c 'KUBE-SVC'
```

```
0
```

**Zero.** On a kube-proxy cluster this number is roughly one chain per Service plus one per
endpoint — dozens on an idle cluster, thousands on a busy one. Here there are none, because no
component is programming them.

(Cilium still uses iptables for *masquerading*, which `cilium-dbg status` reports as
`Masquerading: IPTables`. That is NAT for egress, not Service load balancing — different job.)

## Part 3 — Cilium says it is doing the work

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep -E 'KubeProxyReplacement|Routing:|Device'
```

```
KubeProxyReplacement:    True   [eth0    172.18.0.4 fc00:f853:ccd:e793::4 fe80::42:acff:fe12:4 (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: Legacy        <- captured before demo 11; now `Host: BPF` (docs/TUNING.md)
Device Mode:             veth
```

- **`KubeProxyReplacement: True`** — the headline. The bracket lists the device Cilium attached its
  eBPF programs to and the addresses it will answer NodePort traffic on.
- `Device Mode: veth` — worth noting for demo 06: this is *not* `netkit`, because this Docker
  Desktop VM's kernel is 6.6.12 and netkit needs ≥6.7.

And the actual service table Cilium is serving from eBPF:

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg service list | head -12
```

```
3    10.11.114.88:80/TCP    ClusterIP      1 => 10.10.3.142:8081/TCP (active)
4    10.11.0.10:53/TCP      ClusterIP      1 => 10.10.1.31:53/TCP (active)
                                           2 => 10.10.1.206:53/TCP (active)
5    10.11.0.10:53/UDP      ClusterIP      1 => 10.10.1.31:53/UDP (active)
                                           2 => 10.10.1.206:53/UDP (active)
6    10.11.0.10:9153/TCP    ClusterIP      1 => 10.10.1.31:9153/TCP (active)
                                           2 => 10.10.1.206:9153/TCP (active)
7    10.11.0.1:443/TCP      ClusterIP      1 => 172.18.0.3:6443/TCP (active)
                                           2 => 172.18.0.4:6443/TCP (active)
```

Read entry **7**: that is `kubernetes.default` — the API Service itself — with the control-plane
nodes as backends, being load-balanced by Cilium. Entries 4–6 are CoreDNS. The cluster's own core
services are running through eBPF.

## Part 4 — and it actually works

A claim about mechanism is worth little if traffic does not flow. `deathstar` is a ClusterIP
Service with two backend pods on two different nodes:

```bash
kubectl --context kind-poc1 get svc deathstar
```

```
NAME        TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
deathstar   ClusterIP   10.11.224.170   <none>        80/TCP    4m55s
```

```bash
for i in 1 2 3 4; do
  kubectl --context kind-poc1 exec tiefighter -- \
    curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing; echo
done
```

```
Ship landed
Ship landed
Ship landed
Ship landed
```

Four requests: DNS resolved through CoreDNS (itself a Service, entry 4 above), the ClusterIP
`10.11.224.170` was translated to a pod IP, and the traffic reached a backend — with no kube-proxy
and no `KUBE-SVC` iptables chain anywhere in the cluster.

## What to take away

| Claim | Evidence |
|---|---|
| kube-proxy is not running | `get daemonset` shows only `cilium`, `cilium-envoy`; `No resources found` for the kube-proxy label |
| kube-proxy never ran | Same query returned nothing at all *before* Cilium was installed (SETUP Step 3) |
| Nothing is programming Service iptables rules | `iptables-save \| grep -c KUBE-SVC` = **0** |
| Cilium is handling Services | `KubeProxyReplacement: True`; `cilium-dbg service list` shows real backends, including `kubernetes.default` |
| Services work | 4/4 ClusterIP requests succeeded across 2 backends on 2 nodes |

The honest caveat: this is a five-node laptop cluster, so it demonstrates **correctness and
mechanism**, not the performance benefit. eBPF's advantage over iptables grows with service count,
and measuring that properly needs a cluster far larger than this one. Demo 06 measures what *can*
be measured here — pod-to-pod throughput — and says plainly what it does not prove.

## Evidence

Captured 2026-09-12 with `scripts/evidence/capture.js` and `scripts/evidence/collect.sh` (both re-runnable; the pod and Cilium output is the recorded file [`output/evidence.txt`](output/evidence.txt)). Every image is what the browser saw, with traffic running.

**Running pods** (from `output/evidence.txt`):

```console
$ kubectl --context kind-poc1 -n kube-system get pods -o wide
NAME                                          READY   STATUS    RESTARTS        AGE    IP            NODE                  NOMINATED NODE   READINESS 
cilium-envoy-4ht26                            1/1     Running   2 (24h ago)     2d2h   172.18.0.5    poc1-worker           <none>           <none>
cilium-envoy-9p6mq                            1/1     Running   2 (24h ago)     2d2h   172.18.0.4    poc1-worker2          <none>           <none>
cilium-envoy-r5c6d                            1/1     Running   2 (24h ago)     2d2h   172.18.0.7    poc1-control-plane2   <none>           <none>
cilium-envoy-v9lk2                            1/1     Running   2 (24h ago)     2d2h   172.18.0.3    poc1-control-plane3   <none>           <none>
cilium-envoy-w7759                            1/1     Running   2 (24h ago)     2d2h   172.18.0.6    poc1-control-plane    <none>           <none>
cilium-ntbb4                                  1/1     Running   0               11h    172.18.0.7    poc1-control-plane2   <none>           <none>
cilium-operator-79d6b9ffd7-57lpg              1/1     Running   8 (64s ago)     8h     172.18.0.7    poc1-control-plane2   <none>           <none>
cilium-pv958                                  1/1     Running   0               11h    172.18.0.3    poc1-control-plane3   <none>           <none>
cilium-qt6nm                                  1/1     Running   0               11h    172.18.0.5    poc1-worker           <none>           <none>
cilium-s2wxk                                  1/1     Running   0               11h    172.18.0.4    poc1-worker2          <none>           <none>
cilium-zdgfx                                  1/1     Running   0               11h    172.18.0.6    poc1-control-plane    <none>           <none>
clustermesh-apiserver-844c48bb9b-sngg7        3/3     Running   2 (8h ago)      8h     10.10.4.2     poc1-worker           <none>           <none>
coredns-789c5fbdb4-qhj2d                      1/1     Running   0               17h    10.10.1.35    poc1-control-plane2   <none>           <none>
```

The Cilium/kubectl commands that prove this demo's claim, with their output, follow the pod listings in [`output/evidence.txt`](output/evidence.txt).
