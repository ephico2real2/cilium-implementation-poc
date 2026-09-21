# Demo 52 — MetalLB announcing a service address over BGP, beside kube-vip

A second Kubernetes cluster in the Colima VM runs MetalLB in BGP mode, peers
with both fabric leaves as AS 65022, and announces a service address the whole
fabric learns. It runs alongside demo 54c's kube-vip cluster on the same node
LAN, so the fabric carries two clusters using two different load-balancer
implementations at once.

Demo 52 runs MetalLB in **L2** mode on Docker Desktop. This is the BGP one, and
the difference is the point: nothing here is a port of that demo.

## What you get

- Two Kubernetes clusters on one node LAN, peering with the same two routers.
- MetalLB in **frr-k8s** mode — `speaker.frr.enabled` is deprecated in 0.16.
- Four BGP sessions, two nodes to two leaves, all **signed with TCP MD5**.
- A door on `10.198.0.70`, reachable from the Mac through the whole fabric.
- The spine holding **two paths** to that address, one per leaf.
- The fabric refusing anything outside `10.198.0.64/26` from AS 65022.

## Architecture

```text
                     the Mac
                        │  route 10.198.0.0/24 via the Colima VM
                        ▼
  ┌──────────────────── the Colima VM (Ubuntu 24.04) ────────────────────┐
  │                                                                      │
  │   edge ── spine ──┬── leaf1 (AS 65101)  172.20.254.11                │
  │   AS 65000  65100 └── leaf2 (AS 65102)  172.20.254.12                │
  │                          │       │                                   │
  │        node LAN kind-eg-colima 172.20.0.0/16                         │
  │          ┌───────────────┴───┐   └───────────────┐                   │
  │          │                   │                   │                   │
  │   eg-poc1-colima       eg-poc2-colima                                │
  │   kube-vip  AS 65021   MetalLB  AS 65022                             │
  │   .3  .4               .5  .6                                        │
  │   door 10.198.0.10     door 10.198.0.70                              │
  └──────────────────────────────────────────────────────────────────────┘
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `eg-poc2-colima` | nodes `172.20.0.5`, `172.20.0.6` | the second kind cluster | kindnet + kube-proxy |
| MetalLB | AS 65022 | frr-k8s speaker on every node | `metallb-frr-k8s` |
| leaf1 / leaf2 | `172.20.254.11` / `.12` | what the cluster peers with | FRR 10.7.1 |
| the door | `10.198.0.70` | a `LoadBalancer` service | two `agnhost` replicas |
| the pool | `10.198.0.64/26` | all this cluster may announce | `EG-POC2-VIPS` on both leaves |

## Prerequisites

- The fabric up with the leaves on the node LAN (demo 46c, plus its `compose.lan-eg.yaml` overlay).

```bash
demos/46-bgp-fabric-colima/apply.sh
```

- The Mac's route to the VIP range, which demo 46c records.

```bash
sudo route -n add -net 10.198.0.0/24 "$(colima list --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["address"])')"
```

- `fs.inotify.max_user_instances` at 512 or more in the VM — a second cluster
  will not start at Ubuntu's default of 128. `scripts/eg-colima-up.sh` sets it.

## Steps

Run `demos/52-eg-poc2-metallb-colima/apply.sh`, or follow it step by step:

### 1. Create the second cluster

It needs its own kind config: both clusters share this node LAN and both peer
with the same leaves, so the pod and service CIDRs must differ.

```bash
EG_COLIMA_CLUSTER=eg-poc2-colima \
EG_COLIMA_KUBECONFIG=$HOME/.kube/config-eg-poc2-colima \
  scripts/eg-colima-up.sh
```

Result: two nodes Ready at `172.20.0.5` and `172.20.0.6`, inside the leaves' listen range.

### 2. Install MetalLB in frr-k8s mode

```bash
helm upgrade --install metallb metallb/metallb --version 0.16.0 \
  -n metallb-system --create-namespace \
  --set speaker.frr.enabled=false --set frrk8s.enabled=true
```

Result: `metallb-controller` 1/1, `metallb-frr-k8s` and `metallb-speaker` ready on both nodes.

### 3. Give MetalLB the password the fabric requires

The leaves carry `neighbor SERVERS password`, so an unsigned speaker never gets
past `Connect`. No committed file here holds the password.

```bash
kubectl -n metallb-system create secret generic fabric-bgp-password \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=bgp --from-literal=password="$FABRIC_BGP_PASSWORD"
```

Result: `secret/fabric-bgp-password created`.

### 4. Configure the pool, the advertisement and both peers

```bash
kubectl apply -f demos/52-eg-poc2-metallb-colima/10-metallb-bgp.yaml
```

Result: `IPAddressPool`, `BGPAdvertisement` and two `BGPPeer` objects, AS 65022 to 65101 and 65102.

### 5. Deploy the door

```bash
kubectl apply -f demos/52-eg-poc2-metallb-colima/20-door.yaml
```

Result: `service: door  external-ip=10.198.0.70`.

### 6. Read the sessions from the routers' side

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-leaf1-1 \
  vtysh -c 'show bgp summary'
```

Result: `172.20.0.5` and `172.20.0.6`, AS 65022, both `Established`.

## Verify

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-spine-1 \
  vtysh -c 'show bgp ipv4 unicast 10.198.0.70/32'
```

```text
spine 2 path(s): 10.200.1.2* 10.200.1.10 aspath=65101 65022
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://10.198.0.70/
```

```text
200
```

```bash
demos/52-eg-poc2-metallb-colima/check.sh
```

```text
demo 52c check: 0 FAIL
```

## Reference

| Setting | Value | Where it is enforced |
|---|---|---|
| cluster ASN | 65022 | `BGPPeer.spec.myASN`; leaf as-path `^65022$` |
| the range | `10.198.0.64/26` | `IPAddressPool`; leaf `EG-POC2-VIPS … ge 32 le 32` |
| prefix length | `/32` per service | `BGPAdvertisement.aggregationLength: 32` |
| session timers | `3 9` | `BGPPeer.holdTime/keepaliveTime`, matching the leaves |
| the password | from `FABRIC_BGP_PASSWORD` | `BGPPeer.passwordSecret` → `fabric-bgp-password` |
| pod / service CIDR | `10.72.0.0/16` / `10.73.0.0/16` | `clusters/eg-poc2-colima.yaml` |

## Troubleshooting

- Sessions stuck in `Connect` — the speaker is not signing. Check the secret
  exists and that `passwordSecret` names it.
- The worker never joins and the kubelet logs `inotify_init: too many open
  files` — `fs.inotify.max_user_instances` is still 128.
- Every `kubectl` row reads "absent" while the fabric rows pass — the script is
  reading demo 54c's cluster; name `EG_COLIMA_CLUSTER` before sourcing the library.

## Clean up

```bash
demos/52-eg-poc2-metallb-colima/cleanup.sh
```

## What's next

- A second door in the anycast range `10.198.0.192/26`, announced from both clusters at once.
- `externalTrafficPolicy: Local`, so a node with no endpoint withdraws its path.
- Taking a leaf away and watching the spine fall to one path.
