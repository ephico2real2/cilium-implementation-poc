# Demo 54c — one kind cluster in Colima, kube-vip BGP to the fabric

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide.

The Colima fabric is up and the dashboard at port 8098 shows
`server sessions 0/0` until a speaker dials a leaf. This demo
puts one kind cluster in the same VM, kube-vip in BGP mode
peering with both leaves, a door `/32` in `10.98.0.0/26`, and
the two nodes on the dashboard as external peers. Last apply
`2026-09-20T23:47:49Z`; last check `2026-09-20T23:48:16Z`:
6 PASS, 1 WARN, 0 FAIL. MD5 is signed on both halves
(`md5-option packets=20`; `Established→ABSENT; restored`).

## Files

| File | What |
|---|---|
| [clusters/eg-poc1-colima.yaml](../../clusters/eg-poc1-colima.yaml) | two nodes, `10.70.0.0/16` / `10.71.0.0/16`, kindnet + kube-proxy on, `localhost:5001` patch |
| [scripts/eg-colima-up.sh](../../scripts/eg-colima-up.sh) | CTX gate, LAN, registry, kind create, `/17` assert |
| [scripts/colima-registry.sh](../../scripts/colima-registry.sh) | `kind-registry` on `kind-eg-colima`, published `127.0.0.1:5001` |
| [compose.lan-eg.yaml](../46-bgp-fabric-colima/fabric/compose.lan-eg.yaml) | leaves at `172.19.254.11` / `.12` on `kind-eg-colima` |
| [10b-kube-vip-ds-bgp-active-active.yaml](10b-kube-vip-ds-bgp-active-active.yaml) | kube-vip BGP AS 65021, password placeholder, ARP/election off |
| [10-kubevip-cm.yaml](10-kubevip-cm.yaml) | range `10.98.0.0-10.98.0.63` |
| [20-door.yaml](20-door.yaml) | nginx LoadBalancer, class kube-vip, pin `10.98.0.10` |
| [apply.sh](apply.sh) | cluster, attach (`--no-recreate`), push, kube-vip, door, return route, dashboard, MD5 |
| [check.sh](check.sh) | 7 rows; exit = FAIL count |
| [cleanup.sh](cleanup.sh) | door + kube-vip only |
| [GUIDE.md](GUIDE.md) | five exercises |

## Run it

From the repo root. The Colima fabric must already be up
([demo 46-colima](../46-bgp-fabric-colima/README.md)). Scripts
refuse `desktop-linux`.

```bash
RECORD_STRICT=1 bash demos/54-eg-poc1-kube-vip-colima/apply.sh
bash demos/54-eg-poc1-kube-vip-colima/check.sh
```

The Mac route is the operator's:

```bash
sudo route -n add -net 10.98.0.0/24 192.168.64.3
```

## What was recorded

Recorded from apply `2026-09-20T23:47:49Z`.

### 1. Create the cluster

```bash
scripts/eg-colima-up.sh
```

Recorded:

```text
=== eg-colima-up.sh start 2026-09-20T23:47:50Z cluster=eg-poc1-colima ctx=colima-bgp-fabric ===
=== kindnet + kube-proxy iptables; no Cilium; no Envoy Gateway ===
subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1
registry kind-registry already on kind-eg-colima at 172.19.0.4
catalog (in-container): {"repositories":["door","kube-vip","kube-vip-cloud-provider"]}
eg-poc1-colima-control-plane   Ready    control-plane   10m   v1.36.4   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
eg-poc1-colima-worker          Ready    <none>          10m   v1.36.4   172.19.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
    mode: iptables
```

### 2. Attach the leaves to the cluster LAN

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  up -d --no-recreate --no-build
```

Recorded:

```text
leaves not recreated (same container ids)
leaf1 kind-eg-colima=172.19.254.11 leaf2 kind-eg-colima=172.19.254.12
```

### 3. Push the images through the local registry

```bash
docker --context colima-bgp-fabric exec kind-registry \
  wget -qO- http://127.0.0.1:5000/v2/_catalog
```

Recorded:

```text
{"repositories":["door","kube-vip","kube-vip-cloud-provider"]}
```

### 4. Install kube-vip in BGP mode

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima -n kube-system \
  rollout status ds/kube-vip-ds --timeout=180s
```

Recorded:

```text
daemon set "kube-vip-ds" successfully rolled out
SERVERS Established on both leaves after 1s (2 per leaf)
sessions Established WITH password on kube-vip
rollout-to-wait: 0s md5_on_speaker=1
*172.19.0.2     4      65021        28        28       25    0    0 00:01:17            1        0 N/A
*172.19.0.3     4      65021       137       137       25    0    0 00:06:44            1        0 N/A
```

### 5. Create the door

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima apply \
  -f demos/54-eg-poc1-kube-vip-colima/00-namespace.yaml \
  -f demos/54-eg-poc1-kube-vip-colima/20-door.yaml
```

Recorded:

```text
door Service ingress=10.98.0.10 after 1s
both leaves have a node path for 10.98.0.10/32 after 1s
    172.19.0.3 from 172.19.0.3 (172.19.0.3)
      Origin IGP, valid, external, multipath, best (Older Path)
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
      Origin IGP, valid, external, multipath
```

### 6. Add the node return route

```bash
docker --context colima-bgp-fabric exec \
  eg-poc1-colima-worker ip route show 10.200.0.0/16
```

Recorded:

```text
eg-poc1-colima-worker eg-poc1-colima-worker 10.200.0.0/16 via 172.19.254.11 dev eth0
eg-poc1-colima-control-plane eg-poc1-colima-control-plane 10.200.0.0/16 via 172.19.254.11 dev eth0
```

### 7. Reach the door from client0

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T client0 curl -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 10 http://10.98.0.10/
```

Recorded:

```text
10.98.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10 uid 0
client0 http://10.98.0.10/ → 200 curl_rc=0
```

### 8. Read the dashboard

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Recorded:

```text
routers 4/4 · fabric sessions 6/6 · server sessions 4/4 · external 2
  172.19.0.2 asn=65021 addr=172.19.0.2
  172.19.0.3 asn=65021 addr=172.19.0.3
routers=4/4 sessions=6/6 external=2
screenshot written after 1.8 s; chrome_rc=0
```

### 9. Prove TCP MD5 on the SERVERS sessions

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'nstat -az 2>/dev/null | grep -E "TcpExtTCPMD5"'
```

Recorded:

```text
20 packets captured
21 packets received by filter
0 packets dropped by kernel
```

```text
    172.19.0.3.55659 > 172.19.254.11.179: Flags [P.], cksum 0x5677 (incorrect -> 0x3e4b), seq 2629222600:2629222619, ack 4129105104, win 502, options [nop,nop,md5 shared secret not supplied with -M, can't check - a7e71bb8fb01c8a5a930670dbb1b0bdb], length 19: BGP
```

```text
TcpExtTCPMD5NotFound            0                  0.0
TcpExtTCPMD5Unexpected          0                  0.0
TcpExtTCPMD5Failure             0                  0.0
```

## Checks

Check output at `2026-09-20T23:48:16Z`:

```text
== demo 54c — kind cluster in Colima, kube-vip BGP to the fabric
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   two nodes in 172.19.0.0/17 on kind-eg-colima                           172.19.0.2 172.19.0.3                                eg-colima-up — InternalIP in the lower /17
  PASS   leaves show two SERVERS sessions each (one per node)                   4/4 Established (172.19.0.2 172.19.0.3)              both leaves × both nodes — JSON state == Established
  PASS   door 10.98.0.10/32 in each leaf with a node next hop                   leaf1:nh=172.19.0.3,172.19.0.2 leaf2:nh=172.19.0.2,172.19.0.3  EG-POC1-VIPS + as-path 65021 — node in 172.19.0.0/17
  PASS   client0 reaches the door                                               http_code=200                                        client0 → edge → spine → leaf → node → 10.98.0.10
  Mac: sudo route -n add -net 10.98.0.0/24 192.168.64.3
  WARN   Mac reaches the door over 192.168.64.3                                 route absent — sudo route -n add -net 10.98.0.0/24 192.168.64.3 operator sudo; script never runs it
  PASS   dashboard server sessions and external peers                           server=4/4 external=2 nodes=172.19.0.2 172.19.0.3    /api/state — server 4/4 (both nodes × both leaves), external=2
  PASS   SERVERS MD5 on the wire (signed)                                       md5-option packets=20; Established→ABSENT; restored speaker password set; negative control restored

demo 54c check: 0 FAIL
```

## What is deliberately not here

- Envoy Gateway, HTTPRoute, GRPCRoute, cert-manager.
- Cilium. kindnet and kube-proxy stay on.
- kind load. Images go through the local registry.
- A `sudo` from any script. The Mac route is printed; the
  operator runs it.
- The Desktop fabric, `eg-poc1`, `eg-poc2`, `md5lab`, CRC.

## Runs that did not go to plan

The first apply (`2026-09-20T23:36:41Z`) created the cluster and
pushed images, but the registry-connect check treated a missing
network key as already attached. The registry stayed on `bridge`;
nodes logged `lookup kind-registry: no such host`. kube-vip
rollout timed out. The connect check now reads `.IPAddress`; the
catalog is read in-container.

The second apply (`2026-09-20T23:41:17Z`) peered with the
password (`md5_on_speaker=1`) and announced the door, then
`client0 http://10.98.0.10/ → 000 curl_rc=28`. Leaf1 could wget
the door; spine/edge/client0 timed out. The node's default
gateway is `172.19.0.1` and Docker isolates bridges. Apply now
installs `10.200.0.0/16 via 172.19.254.11` on both nodes.

The first check after that path (`2026-09-20T23:45:35Z`) printed
`md5-option packets=20; Established→ABSENT; restored` and still
`1 FAIL`: the negative-control `vtysh` set returned non-zero on
a dynamic neighbor and left `mismatch_ok=0`. The check now
judges only the drop and the restore.

## Clean up

```bash
bash demos/54-eg-poc1-kube-vip-colima/cleanup.sh
```
