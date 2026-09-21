# demo 52c — exercises

Five read-only things to try once the demo is up, to see how a cluster and a
fabric agree on an address.

## Prerequisites

- Demo 52c applied, and the fabric up.

```bash
demos/52-eg-poc2-metallb-colima/apply.sh
```

- The dashboard, which shows both clusters at once.

```bash
open http://127.0.0.1:8098/
```

## Exercises

### 1. Ask a leaf who is peering with it

A leaf does not know the word "MetalLB". It knows AS numbers and addresses.

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-leaf1-1 \
  vtysh -c 'show bgp summary'
```

**Expect:**

```text
172.20.0.3  AS65021 Established   <- kube-vip, demo 54c
172.20.0.4  AS65021 Established
172.20.0.5  AS65022 Established   <- MetalLB, this demo
172.20.0.6  AS65022 Established
```

### 2. Read the two doors side by side

Two clusters, two implementations, one table. The as-path says which is which.

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-edge-1 \
  vtysh -c 'show bgp ipv4 unicast'
```

**Expect:**

```text
10.198.0.10/32  ... 65100 65101 65021   <- kube-vip's door
10.198.0.70/32  ... 65100 65101 65022   <- MetalLB's door
```

### 3. Count the paths the spine holds

Both leaves learn the door, so the spine has two ways to reach it.

```bash
docker --context colima-bgp-fabric exec bgp-fabric-colima-spine-1 \
  vtysh -c 'show bgp ipv4 unicast 10.198.0.70/32'
```

**Expect:**

```text
2 path(s): 10.200.1.2* 10.200.1.10 aspath=65101 65022
```

### 4. Ask MetalLB's own FRR what it thinks

The speaker runs FRR too. Its view should mirror the leaves'.

```bash
kubectl --context kind-eg-poc2-colima -n metallb-system \
  exec ds/metallb-frr-k8s -c frr -- vtysh -c 'show bgp summary'
```

**Expect:**

```text
local AS number 65022
172.20.254.11   4  65101  ... Established
172.20.254.12   4  65102  ... Established
```

### 5. Reach the door through the whole fabric

From the Mac, the packet crosses the VM boundary, the fabric and the node LAN.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://10.198.0.70/
```

**Expect:**

```text
200
```

## Clean up

See the README's [Clean up](README.md#clean-up).
