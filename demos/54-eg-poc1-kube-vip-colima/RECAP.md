# Demo 54 — a kind cluster in Colima that peers with the fabric

This page builds one kind cluster, `eg-poc1-colima`, inside the same
Colima VM as the [demo 46-colima](../46-bgp-fabric-colima/RECAP.md)
fabric. kube-vip (a DaemonSet that speaks BGP) peers with both
leaves as AS 65021; a LoadBalancer door at `10.98.0.10` appears in
the leaves' tables; the dashboard on port 8098 shows the two nodes
as external peers. Envoy Gateway is not here — this demo is the
cluster talking to the fabric.

## What you get

- Apply `2026-09-20T23:47:49Z`. Cluster `eg-poc1-colima` on the
  kind-eg-colima LAN: kindnet `2/2`, kube-proxy `iptables` `2/2`,
  no Cilium. Nodes `172.19.0.2` (worker) and `172.19.0.3`
  (control-plane), kernel `6.8.0-117-generic`, Kubernetes `v1.36.4`.
- Leaves attached at `172.19.254.11` / `.12` without recreate
  (`f59f78be…`, `a318ec6c…`). The local registry (kind-registry)
  sits at `172.19.0.4`; catalog `door`, `kube-vip`,
  `kube-vip-cloud-provider`.
- kube-vip BGP AS 65021, password set (`md5_on_speaker=1`).
  `SERVERS Established on both leaves after 1s (2 per leaf)`.
- Door `10.98.0.10` after 1 s; each leaf has a node path for
  `10.98.0.10/32` after 1 s (AS 65021, ECMP both nodes).
- Node return route `10.200.0.0/16 via 172.19.254.11`. `client0`
  `http://10.98.0.10/` → `200 curl_rc=0`.
- Dashboard `routers 4/4 · fabric sessions 6/6 · server sessions 4/4
  · external 2`. Screenshot `1200 x 700` after 1.8 s.
- Apply captured `20 packets captured` on leaf1, each
  `options [nop,nop,md5 …]`. Check: `md5-option packets=20;
  Established→ABSENT; restored`. Both halves signed.
- `check.sh` at `2026-09-20T23:48:16Z`: 6 PASS, 1 WARN (Mac route
  absent — the operator runs `sudo`), 0 FAIL.

## Architecture

A request from `client0` to the door takes this path. The Mac
reaches the same VIP over a route to the Colima VM:

```text
 MacBook                         Colima VM (profile bgp-fabric)
 browser 127.0.0.1:8098          kernel 6.8.0-117-generic
        |                        context colima-bgp-fabric
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
        | 172.19.254.11           172.19.254.12
        |     \   /
        |      v v
        | kind-eg-colima 172.19.0.0/16 (ip-range /17)
        |   worker .2  AS 65021   control-plane .3  AS 65021
        |   kube-vip (both leaves)     kube-vip (both leaves)
        |              \   /
        |               v
        |         door 10.98.0.10/32
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| worker | `172.19.0.2` | kind node, kube-vip AS 65021 | leaf1 + leaf2 |
| control-plane | `172.19.0.3` | kind node, kube-vip AS 65021 | leaf1 + leaf2 |
| leaf1 / leaf2 | `172.19.254.11` / `.12` | fabric leaves on the cluster LAN | SERVERS listen `172.19.0.0/17` |
| door | `10.98.0.10` | LoadBalancer, kube-vip class, pin in `10.98.0.0/26` | nginx on either node (ECMP) |
| dashboard | `127.0.0.1:8098` | fabric poller | `server sessions 4/4`, `external 2` |

The node's default gateway is `172.19.0.1`. Return traffic for the
company fabric (`10.200.0.0/16`) must go via a leaf — Docker
isolates bridges. The Mac route is the operator's; scripts never
run `sudo`.

## Prerequisites

- Demo 46-colima fabric up (project `bgp-fabric-colima`, context
  `colima-bgp-fabric`). Scripts refuse any other context.
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  kube-vip `v1.2.4`, cloud-provider `v0.0.12`, kind node
  `kindest/node:v1.36.4`.
- Chrome at
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
  for the screenshot.
- A route on the Mac to the VIP block (the operator runs this;
  recorded as absent):

```bash
sudo route -n add -net 10.98.0.0/24 192.168.64.3
```

## Steps

Bring the cluster up, attach it to the fabric, and read the proof:

### 1. Create the cluster

The builder creates the kind-eg-colima LAN (`172.19.0.0/16`,
ip-range `/17`), starts the local registry on that LAN, and
creates `eg-poc1-colima` with kindnet and kube-proxy left on.

```bash
scripts/eg-colima-up.sh
```

Result: `subnet=172.19.0.0/16 ip-range=172.19.0.0/17
gateway=172.19.0.1`; nodes Ready at `172.19.0.3` and `172.19.0.2`;
kindnet `2/2`, kube-proxy `mode: iptables`; catalog
`{"repositories":["door","kube-vip","kube-vip-cloud-provider"]}`.

### 2. Attach the leaves to the cluster LAN

Compose with both files, `--no-recreate`. If the overlay does not
add the LAN, connect by address.

```bash
RECORD_STRICT=1 bash demos/54-eg-poc1-kube-vip-colima/apply.sh
```

Result: `leaves not recreated (same container ids)`;
`leaf1 kind-eg-colima=172.19.254.11 leaf2 kind-eg-colima=172.19.254.12`.

### 3. Push the images through the local registry

Images go to `localhost:5001`. No kind load. The catalog is
read from inside the registry container (the Mac's `:5001` may be
Desktop's).

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

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima -n kube-system \
  rollout status ds/kube-vip-ds --timeout=180s
```

Result: `daemon set "kube-vip-ds" successfully rolled out`;
`SERVERS Established on both leaves after 1s (2 per leaf)`;
`rollout-to-wait: 0s md5_on_speaker=1`; leaf1 neighbors
`*172.19.0.2` and `*172.19.0.3` AS 65021.

### 5. Create the door

A LoadBalancer on the kube-vip class, pinned to `10.98.0.10`
([`20-door.yaml`](20-door.yaml)). No Envoy Gateway.

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima -n door get svc door \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Result: `door Service ingress=10.98.0.10 after 1s`;
`both leaves have a node path for 10.98.0.10/32 after 1s`;
leaf1 paths `172.19.0.3` and `172.19.0.2`, AS 65021, multipath.

### 6. Add the node return route

The nodes' default gateway is the docker bridge. Return traffic
for the fabric must go through a leaf.

```bash
docker --context colima-bgp-fabric exec \
  eg-poc1-colima-worker ip route show 10.200.0.0/16
```

Result: `eg-poc1-colima-worker 10.200.0.0/16 via 172.19.254.11
dev eth0`; the same on the control-plane.

### 7. Reach the door from client0

`client0` defaults via the edge. The path is edge → spine → leaf
→ node → `10.98.0.10`.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T client0 curl -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 10 http://10.98.0.10/
```

Result: `10.98.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10`;
`client0 http://10.98.0.10/ → 200 curl_rc=0`.

### 8. Read the dashboard

The poller on port 8098 now has the two nodes as external peers.
That is the row that answers "I don't see any connection on 8098".

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Result: `routers 4/4 · fabric sessions 6/6 · server sessions 4/4
· external 2`; peers `172.19.0.2` and `172.19.0.3` AS 65021;
`screenshot written after 1.8 s; chrome_rc=0`.

### 9. Prove TCP MD5 on the SERVERS sessions

tcpdump in leaf1's netns must see the TCP-MD5 option. Zero
packets is a FAIL. Kernel counters at zero are not enough.

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'nstat -az 2>/dev/null | grep -E "TcpExtTCPMD5"'
```

Result: `20 packets captured`, each `options [nop,nop,md5 …]`;
`TcpExtTCPMD5{NotFound,Unexpected,Failure}` all 0. Gobgp set
`TCP_MD5SIG` on this kernel (`md5_on_speaker=1`). Both halves
are signed.

## Verify

The Mac route (operator), then the check (the MD5 row changes one
session and restores it):

```bash
sudo route -n add -net 10.98.0.0/24 192.168.64.3
```

```bash
bash demos/54-eg-poc1-kube-vip-colima/check.sh
```

Result: `2026-09-20T23:48:16Z`, 6 PASS, 1 WARN (Mac route
absent), 0 FAIL; `server=4/4 external=2`; `md5-option packets=20;
Established→ABSENT; restored`; `demo 54c check: 0 FAIL`.

## Reference

| Item | Value |
|---|---|
| docker context | `colima-bgp-fabric` (scripts refuse any other name) |
| Colima profile | `bgp-fabric` |
| compose project | `bgp-fabric-colima` |
| cluster | `eg-poc1-colima` — kubeconfig `$HOME/.kube/config-eg-poc1-colima` |
| node LAN | `kind-eg-colima` `172.19.0.0/16`, ip-range `/17` |
| registry | `kind-registry` on that LAN, published `127.0.0.1:5001` |
| speaker | kube-vip `v1.2.4`, AS 65021, password `FABRIC_BGP_PASSWORD` |
| door | `10.98.0.10` in `10.98.0.0/26` (`EG-POC1-VIPS`) |
| dashboard | `127.0.0.1:8098` |
| last apply | `2026-09-20T23:47:49Z` |
| last check | `2026-09-20T23:48:16Z` |
| files | [README.md](README.md), [GUIDE.md](GUIDE.md) |

## Troubleshooting

- Symptom: script prints `refusing` and exits. Cause: `CTX` is
  not `colima-bgp-fabric`. Fix: start the profile with the fabric
  up script; do not switch the active context.
- Symptom: `client0` times out (`curl_rc=28`) while a leaf can
  reach the door. Cause: the node has no return route to
  `10.200.0.0/16`. Fix: re-run apply (step 6).
- Symptom: Mac `:5001` catalog is not this cluster's. Cause:
  Desktop's registry is published on the same port. Fix: read the
  catalog from inside the registry container.

## Clean up

Removes the door and kube-vip. Leaves the cluster, the registry,
the LAN, the fabric and the Colima VM. Desktop is untouched.

```bash
bash demos/54-eg-poc1-kube-vip-colima/cleanup.sh
```

## What's next

- Add the Mac route and curl the door from the host.
- [GUIDE.md](GUIDE.md) — five exercises, including the dashboard
  line and the check's mismatch row.
- Demo 52c — MetalLB's FRR-K8s speaker on the same fabric.
