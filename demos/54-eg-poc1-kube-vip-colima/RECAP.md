# Demo 54 — a kind cluster in Colima that peers with the fabric

This page builds one kind cluster, `eg-poc1-colima`, inside the same
Colima VM as the [demo 46-colima](../46-bgp-fabric-colima/RECAP.md)
fabric. kube-vip (a DaemonSet that speaks BGP) peers with both
leaves as AS 65021; a LoadBalancer door at `10.198.0.10` appears in
the leaves' tables; the dashboard on port 8098 shows the two nodes
as external peers. Envoy Gateway is not here — this demo is the
cluster talking to the fabric.

## What you get

- Apply `2026-09-21T00:35:36Z`. Cluster `eg-poc1-colima` on the
  kind-eg-colima LAN: kindnet `2/2`, kube-proxy `iptables` `2/2`,
  no Cilium. Nodes `172.20.0.4` (worker) and `172.20.0.3`
  (control-plane), kernel `6.8.0-117-generic`, Kubernetes `v1.36.4`.
- Leaves attached at `172.20.254.11` / `.12` without recreate
  (`leaves not recreated (same container ids)`). The local registry
  (kind-registry) sits at `172.20.0.2`; catalog `door`, `kube-vip`,
  `kube-vip-cloud-provider`.
- kube-vip BGP AS 65021, password set (`md5_on_speaker=1`); leaf1
  neighbors `*172.20.0.3` and `*172.20.0.4` Established (0 prefixes
  at peer-up; the door `/32` arrives in the next step).
- Door `10.198.0.10` after 1 s; each leaf has a node path for
  `10.198.0.10/32` after 1 s (AS 65021, ECMP both nodes).
- Node return route `10.200.0.0/16 via 172.20.254.11`. `client0`
  `http://10.198.0.10/` → `200 curl_rc=0`.
- VM route `10.198.0.0/24 via 172.20.254.11` and a `DOCKER-USER`
  accept toward the node-LAN bridge; the Mac's route goes to the
  VM's vzNAT address `192.168.64.4`.
- Dashboard `routers 4/4 · fabric sessions 6/6 · server sessions 4/4
  · external 2`. Screenshot `1200 x 700` after 1.8 s.
- Apply captured `20 packets captured` on leaf1, each
  `options [nop,nop,md5 …]`; leaf1's own
  `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all 0 while healthy.
  Check: `wrong key on leaf1: 0/2 up in 10/10 samples, MD5Failure
  +14; restored in 9s`. Both halves signed, and the kernel enforces
  it.
- `check.sh` at `2026-09-21T00:36:14Z`: 7 PASS, 0 WARN, 0 FAIL.
  The Mac route `10.198.0.0/24 → 192.168.64.4` is in place
  (`http_code=200`).

## Architecture

A request from `client0` to the door takes this path. The Mac
reaches the same VIP over a route to the Colima VM's vzNAT
address:

```text
 MacBook                         Colima VM (profile bgp-fabric)
 browser 127.0.0.1:8098          kernel 6.8.0-117-generic
 route 10.198.0.0/24 → .64.4     col0 192.168.64.4, context colima-bgp-fabric
        |                        DOCKER-USER: accept 10.198.0.0/24 → node-LAN bridge
        |   client0 10.200.100.10
        |      |
        |      v
        |   edge AS 65000
        |      |
        |      v
        |   spine AS 65100
        |     / \
        |    v   v
        | leaf1 AS 65101          leaf2 AS 65102
        | 172.20.254.11           172.20.254.12
        |     \   /
        |      v v
        | kind-eg-colima 172.20.0.0/16 (ip-range /17)
        |   worker .4  AS 65021   control-plane .3  AS 65021
        |   kube-vip (both leaves)     kube-vip (both leaves)
        |              \   /
        |               v
        |         door 10.198.0.10/32
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| worker | `172.20.0.4` | kind node, kube-vip AS 65021 | leaf1 + leaf2 |
| control-plane | `172.20.0.3` | kind node, kube-vip AS 65021 | leaf1 + leaf2 |
| leaf1 / leaf2 | `172.20.254.11` / `.12` | fabric leaves on the cluster LAN | SERVERS listen `172.20.0.0/17` |
| door | `10.198.0.10` | LoadBalancer, kube-vip class, pin in `10.198.0.0/26` | nginx on either node (ECMP) |
| VM | `192.168.64.4` | the profile's vzNAT address (`colima list` → ADDRESS) | the Mac's next hop for `10.198.0.0/24` |
| dashboard | `127.0.0.1:8098` | fabric poller | `server sessions 4/4`, `external 2` |

The node's default gateway is `172.20.0.1`. Return traffic for the
company fabric (`10.200.0.0/16`) must go via a leaf — Docker
isolates bridges. Traffic entering the VM from outside a docker
bridge needs the `DOCKER-USER` accept — Docker 29's `FORWARD`
policy is `DROP`. The Mac route is the operator's; scripts never
run `sudo` on the Mac.

## Prerequisites

- Demo 46-colima fabric up (project `bgp-fabric-colima`, context
  `colima-bgp-fabric`). Scripts refuse any other context.
- The profile runs with a reachable address
  (`scripts/fabric-colima-up.sh` creates it with
  `--network-address`; an older profile without one is restarted:
  `colima stop --profile bgp-fabric && colima start --profile
  bgp-fabric --network-address --activate=false`). `192.168.64.3`
  is the `md5lab` profile — never this VM.
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  kube-vip `v1.2.4`, cloud-provider `v0.0.12`, kind node
  `kindest/node:v1.36.4`.
- Chrome at
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
  for the screenshot.
- A route on the Mac to the VIP block (the operator runs this;
  already in place on this Mac):

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

## Steps

Bring the cluster up, attach it to the fabric, and read the proof:

### 1. Create the cluster

The builder creates the kind-eg-colima LAN (`172.20.0.0/16`,
ip-range `/17`), starts the local registry on that LAN, and
creates `eg-poc1-colima` with kindnet and kube-proxy left on.

```bash
scripts/eg-colima-up.sh
```

Result: `subnet=172.20.0.0/16 ip-range=172.20.0.0/17
gateway=172.20.0.1`; nodes Ready at `172.20.0.3` and `172.20.0.4`;
kindnet `2/2`, kube-proxy `mode: iptables`; catalog
`{"repositories":["door","kube-vip","kube-vip-cloud-provider"]}`.

### 2. Attach the leaves to the cluster LAN

Compose with both files, `--no-recreate`. If the overlay does not
add the LAN, connect by address.

```bash
RECORD_STRICT=1 bash demos/54-eg-poc1-kube-vip-colima/apply.sh
```

Result: `leaves not recreated (same container ids)`;
`leaf1 kind-eg-colima=172.20.254.11 leaf2 kind-eg-colima=172.20.254.12`.

### 3. Push the images through the local registry

Images go to `localhost:5001`. No kind load. The catalog is read
from inside the registry container: the Mac's `127.0.0.1:5001` is
forwarded by the `md5lab` profile's ssh forwarder (it published
5001 first), so it answers with that registry's catalog, not this
one's.

```bash
docker --context colima-bgp-fabric exec kind-registry \
  wget -qO- http://127.0.0.1:5000/v2/_catalog
```

Result:
`{"repositories":["door","kube-vip","kube-vip-cloud-provider"]}`.

### 4. Install kube-vip in BGP mode

AS 65021, both leaves as peers, password from
`FABRIC_BGP_PASSWORD`, `vip_arp` / `svc_election` /
`vip_leaderelection` all false
([`10b-kube-vip-ds-bgp-active-active.yaml`](10b-kube-vip-ds-bgp-active-active.yaml)).
kube-vip v1.2.4 carries gobgp v4.9.0, whose dialer sets
`TCP_MD5SIG` inside its `Control` callback and aborts the dial if
that fails — on this kernel it does not fail.

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima -n kube-system \
  rollout status ds/kube-vip-ds --timeout=180s
```

Result: `daemon set "kube-vip-ds" successfully rolled out`;
`rollout-to-wait: 3s md5_on_speaker=1`; leaf1 neighbors
`*172.20.0.3` and `*172.20.0.4` AS 65021, 0 prefixes each.

### 5. Create the door

A LoadBalancer on the kube-vip class, pinned to `10.198.0.10`
([`20-door.yaml`](20-door.yaml)). No Envoy Gateway.

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima -n door get svc door \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Result: `door Service ingress=10.198.0.10 after 1s`;
`both leaves have a node path for 10.198.0.10/32 after 1s`;
leaf1 paths `172.20.0.3` (best, Router ID) and `172.20.0.4`, AS 65021,
multipath; leaf2 the same two plus the spine's echo via `10.200.1.11`.

### 6. Add the node return route

The nodes' default gateway is the docker bridge. Return traffic
for the fabric must go through a leaf.

```bash
docker --context colima-bgp-fabric exec \
  eg-poc1-colima-worker ip route show 10.200.0.0/16
```

Result: `eg-poc1-colima-worker 10.200.0.0/16 via 172.20.254.11
dev eth0`; the same on the control-plane.

### 7. Reach the door from client0

`client0` defaults via the edge. The path is edge → spine → leaf
→ node → `10.198.0.10`.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T client0 curl -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 10 http://10.198.0.10/
```

Result: `10.198.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10`;
`client0 http://10.198.0.10/ → 200 curl_rc=0`.

### 8. Open the VM's forward path and print the Mac's route

Apply installs the VM's route for the VIP block via leaf1 and a
`DOCKER-USER` accept toward the node-LAN bridge, then prints the
Mac's line with the profile's real address. Measured with a
throwaway netns in the VM standing in for the Mac: the route alone
gives `curl_rc=28`; with the accept, `200`.

```bash
colima ssh --profile bgp-fabric -- sudo sh -c \
  'ip route show 10.198.0.0/24 && iptables -S DOCKER-USER'
```

Result: `10.198.0.0/24 via 172.20.254.11 dev br-fde14ce0c6b3`;
`-A DOCKER-USER -d 10.198.0.0/24 -o br-fde14ce0c6b3 -j ACCEPT`;
`Mac: sudo route -n add -net 10.198.0.0/24 192.168.64.4`;
`Mac route in place:`; `mac http://10.198.0.10/ → 200 curl_rc=0`.

### 9. Read the dashboard

The poller on port 8098 now has the two nodes as external peers.
That is the row that answers "I don't see any connection on 8098".

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Result: `routers 4/4 · fabric sessions 6/6 · server sessions 4/4
· external 2`; peers `172.20.0.3` and `172.20.0.4` AS 65021;
`screenshot written after 1.8 s; chrome_rc=0`.

### 10. Prove TCP MD5 on the SERVERS sessions

tcpdump in leaf1's netns must see the TCP-MD5 option. Zero
packets is a FAIL. Kernel counters at zero are not enough on
their own, and they are per namespace — read them in leaf1's.

```bash
docker --context colima-bgp-fabric run --rm \
  --net container:bgp-fabric-colima-leaf1-1 nicolaka/netshoot:v0.16 \
  sh -c 'nstat -az | grep -E "TcpExtTCPMD5"'
```

Result: `20 packets captured`, each `options [nop,nop,md5 …]`;
leaf1's `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all 0. Gobgp
set `TCP_MD5SIG` on this kernel (`md5_on_speaker=1`). Both halves
are signed.

## Verify

The Mac route (operator), then the check. The MD5 row is the
negative control: it puts a wrong key on leaf1's SERVERS
peer-group, expects both node sessions to stay down for 10 s while
leaf1's `TcpExtTCPMD5Failure` climbs, then restores the key and
expects both back. leaf2 is untouched, so the door keeps answering.

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

```bash
bash demos/54-eg-poc1-kube-vip-colima/check.sh
```

Result: `2026-09-21T00:36:14Z`, 7 PASS, 0 WARN, 0 FAIL;
`server=4/4 external=2`; Mac `http_code=200`;
`md5-option packets=20; wrong key on leaf1: 0/2 up in 10/10
samples, MD5Failure +14; restored in 9s`; `demo 54c check: 0 FAIL`.

## Reference

| Item | Value |
|---|---|
| docker context | `colima-bgp-fabric` (scripts refuse any other name) |
| Colima profile | `bgp-fabric`, vzNAT address `192.168.64.4` (`--network-address`) |
| compose project | `bgp-fabric-colima` |
| cluster | `eg-poc1-colima` — kubeconfig `$HOME/.kube/config-eg-poc1-colima` |
| node LAN | `kind-eg-colima` `172.20.0.0/16`, ip-range `/17`; bridge `br-fde14ce0c6b3` in the VM |
| registry | `kind-registry` on that LAN, published `127.0.0.1:5001` inside the VM (the Mac's 5001 is `md5lab`'s) |
| speaker | kube-vip `v1.2.4` (gobgp v4.9.0), AS 65021, password `FABRIC_BGP_PASSWORD` |
| door | `10.198.0.10` in `10.198.0.0/26` (`EG-POC1-VIPS`) |
| dashboard | `127.0.0.1:8098` |
| last apply | `2026-09-21T00:35:36Z` |
| last check | `2026-09-21T00:36:14Z` |
| files | [README.md](README.md), [GUIDE.md](GUIDE.md) |

## Troubleshooting

- Symptom: script prints `refusing` and exits. Cause: `CTX` is
  not `colima-bgp-fabric`. Fix: start the profile with the fabric
  up script; do not switch the active context.
- Symptom: `client0` times out (`curl_rc=28`) while a leaf can
  reach the door. Cause: the node has no return route to
  `10.200.0.0/16`. Fix: re-run apply (step 6).
- Symptom: the Mac's curl times out although its route is in
  place. Cause: the VM's `DOCKER-USER` accept is missing (a VM
  restart clears it) or the route points at another profile's
  address. Fix: re-run apply (step 8); check `colima list` for
  this profile's `ADDRESS`.
- Symptom: `colima list` shows no `ADDRESS` for `bgp-fabric`.
  Cause: the profile was created without `--network-address`.
  Fix: `colima stop --profile bgp-fabric && colima start --profile
  bgp-fabric --network-address --activate=false`, then the fabric
  up script and apply again.
- Symptom: Mac `:5001` catalog is not this cluster's. Cause: the
  `md5lab` profile's ssh forwarder holds the Mac's 5001. Fix: read
  the catalog from inside the registry container.

## Clean up

Removes the door and kube-vip. Leaves the cluster, the registry,
the LAN, the fabric and the Colima VM. Desktop is untouched.

```bash
bash demos/54-eg-poc1-kube-vip-colima/cleanup.sh
```

## What's next

- [GUIDE.md](GUIDE.md) — five exercises, including the dashboard
  line and the check's negative control.
- Demo 52c — MetalLB's FRR-K8s speaker on the same fabric.
