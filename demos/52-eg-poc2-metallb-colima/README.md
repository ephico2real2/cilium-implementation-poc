# demo 52c — MetalLB in BGP mode on a second Colima cluster

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide.

A second kind cluster in the Colima VM runs MetalLB in BGP (frr-k8s) mode as
AS 65022, peers with both fabric leaves, and announces a door the whole fabric
learns. It sits beside demo 54c's kube-vip cluster on the same node LAN, so the
fabric carries two clusters using two different load-balancer implementations.

Demo 52 (Docker Desktop) runs MetalLB in L2 mode. This one is BGP.

## Files

| File | What |
|---|---|
| `apply.sh` | the whole demo, idempotent |
| `check.sh` | 11 PASS/FAIL rows; exit = FAIL count |
| `cleanup.sh` | deletes this cluster only — the fabric and 54c stay |
| `10-metallb-bgp.yaml` | pool, advertisement, both peers |
| `20-door.yaml` | the namespace, the deployment and the LoadBalancer service |
| `../../clusters/eg-poc2-colima.yaml` | the kind config, with its own pod/service CIDRs |
| `output/` | the transcript, the check table and the captures |

## Run it

```bash
demos/46-bgp-fabric-colima/apply.sh
```

```bash
demos/52-eg-poc2-metallb-colima/apply.sh
```

```bash
demos/52-eg-poc2-metallb-colima/check.sh
```

## What was recorded

### 1. Create the second cluster

```bash
EG_COLIMA_CLUSTER=eg-poc2-colima scripts/eg-colima-up.sh
```

```text
eg-poc2-colima-control-plane   Ready   172.20.0.6
eg-poc2-colima-worker          Ready   172.20.0.5
```

### 2. MetalLB in frr-k8s mode

```bash
helm upgrade --install metallb metallb/metallb --version 0.16.0 --set frrk8s.enabled=true
```

```text
deployment.apps/metallb-controller   1/1
daemonset.apps/metallb-frr-k8s       2
daemonset.apps/metallb-speaker       2
```

### 3. The sessions, from the routers' side

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-leaf1-1 vtysh -c 'show bgp summary'
```

```text
leaf1 172.20.0.5     AS65022 Established  pfxRcd=1
leaf1 172.20.0.6     AS65022 Established  pfxRcd=1
leaf2 172.20.0.5     AS65022 Established  pfxRcd=1
leaf2 172.20.0.6     AS65022 Established  pfxRcd=1
```

### 4. The /32 through the fabric, and the door from the Mac

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-spine-1 vtysh -c 'show bgp ipv4 unicast 10.198.0.70/32'
```

```text
leaf1 1 path(s): 172.20.0.5* aspath=65022
spine 2 path(s): 10.200.1.2* 10.200.1.10 aspath=65101 65022
edge 1 path(s): 10.200.1.18* aspath=65100 65101 65022
curl http://10.198.0.70/ -> 200
```

### 5. Both clusters on one fabric

```bash
curl -s http://127.0.0.1:8098/api/state
```

```text
serverSessions=8 serverEstablished=8 external=4
AS65021: 172.20.0.3 172.20.0.4
AS65022: 172.20.0.5 172.20.0.6
```

## Checks

```text
== demo 52c — MetalLB in BGP mode on a second Colima cluster (AS 65022)
  STATUS WHAT                                                           MEASURED                                                 RULE
  PASS   both Colima clusters exist                                     eg-poc1-colima eg-poc2-colima                            52c runs beside 54c on kind-eg-colima
  PASS   the two clusters' pod CIDRs differ                             poc1 10.70.0.0/16 vs poc2 10.72.0.0/16                   one node LAN, two clusters: no shared pod CIDR
  PASS   fs.inotify.max_user_instances raised                           instances=512                                            128 starts one cluster and fails the second
  PASS   MetalLB running frr-k8s (not the deprecated FRR mode)          metallb-frr-k8s ready=2                                  0.16 deprecates speaker.frr.enabled
  PASS   four AS 65022 sessions Established (2 nodes x 2 leaves)        4/4 Established                                          two nodes x two leaves
  PASS   the sessions are signed (TCP MD5)                              leaf1 requires a password; secret/fabric-bgp-password supplies it MetalLB stays in Connect unsigned
  PASS   the door holds 10.198.0.70 from 10.198.0.64/26                 external-ip=10.198.0.70                                  EG-POC2-VIPS permits 10.198.0.64/26 ge 32 le 32
  PASS   spine has two paths to 10.198.0.70 (one per leaf)              paths=2                                                  ECMP: a leaf may be lost
  PASS   the edge sees it via the whole fabric                          aspath=65100 65101 65022                                 spine, a leaf, then the cluster
  PASS   the door answers from the Mac                                  curl http://10.198.0.70/ -> 200                          route via the Colima VM address
  PASS   the leaf filters this cluster to its own /26                   EG-POC2-VIPS 10.198.0.64/26 ge 32 le 32                  a cluster may not announce another's range

demo 52c check: 0 FAIL
```

## What is deliberately not here

- **No Cilium.** kindnet and kube-proxy, as demo 54c uses.
- **No Envoy Gateway.** The door is a plain LoadBalancer service; this demo is about BGP.
- **No L2 mode.** That is demo 52 on Docker Desktop, and it is a different lesson.
- **No password in any committed file**, the same rule `frr.conf` follows.
- **The old lab is untouched.** Demo 52 on Docker Desktop stays as it is.

## Runs that did not go to plan

**The second cluster would not start**, and kubeadm blamed cgroups:
`The kubelet is unhealthy due to a misconfiguration of the node in some way
(required cgroups disabled)`. The kubelet's own log named the real cause —
`inotify_init: too many open files` — and `fs.inotify.max_user_instances` was
Ubuntu's default 128. One cluster survives that; a second does not.
`scripts/eg-colima-up.sh` raises it to 512 now.

**The bring-up script hardcoded `clusters/eg-poc1-colima.yaml`**, so the second
cluster booted with the first one's pod and service CIDRs. It picks the config
by cluster name now, and `eg-poc2-colima.yaml` carries `10.72.0.0/16` and
`10.73.0.0/16`.

**MetalLB sat in `Connect`.** The leaves carry `neighbor SERVERS password`, so
the TCP handshake was dropped before BGP was spoken. `passwordSecret` fixed it
and proves MetalLB does TCP MD5 on this kernel.

**The check reported the lab broken when it was not.** Every `kubectl` row read
"absent" while every fabric row passed, because `fabric-colima-lib.sh` defaults
`EG_COLIMA_CLUSTER` to demo 54c's cluster and the script computed its own after
sourcing it — so it queried `--context kind-eg-poc1-colima`. The cluster is
named before the library is sourced now.

## Clean up

```bash
demos/52-eg-poc2-metallb-colima/cleanup.sh
```
