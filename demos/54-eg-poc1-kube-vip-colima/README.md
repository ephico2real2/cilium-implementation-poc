# Demo 54c — one kind cluster in Colima, kube-vip BGP to the fabric

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide.

The Colima fabric is up and the dashboard at port 8098 shows
`server sessions 0/0` until a speaker dials a leaf. This demo
puts one kind cluster in the same VM, kube-vip in BGP mode
peering with both leaves, a door `/32` in `10.198.0.0/26`, and
the two nodes on the dashboard as external peers. Last apply
`2026-09-21T00:35:36Z`; last check `2026-09-21T00:36:14Z`:
7 PASS, 0 WARN, 0 FAIL. MD5 is signed on both halves, and the
check proves it the only way that counts: a wrong peer-group key
on leaf1 keeps both node sessions down for the whole hold window
while the leaf's own `TcpExtTCPMD5Failure` climbs (`+14`), and the
right key brings them back (`restored in 9s`).

## Files

| File | What |
|---|---|
| [clusters/eg-poc1-colima.yaml](../../clusters/eg-poc1-colima.yaml) | two nodes, `10.70.0.0/16` / `10.71.0.0/16`, kindnet + kube-proxy on, `localhost:5001` patch |
| [scripts/eg-colima-up.sh](../../scripts/eg-colima-up.sh) | CTX gate, LAN, registry, kind create, `/17` assert |
| [scripts/colima-registry.sh](../../scripts/colima-registry.sh) | `kind-registry` on `kind-eg-colima`, published `127.0.0.1:5001` |
| [compose.lan-eg.yaml](../46-bgp-fabric-colima/fabric/compose.lan-eg.yaml) | leaves at `172.20.254.11` / `.12` on `kind-eg-colima` |
| [10b-kube-vip-ds-bgp-active-active.yaml](10b-kube-vip-ds-bgp-active-active.yaml) | kube-vip BGP AS 65021, password placeholder, ARP/election off |
| [10-kubevip-cm.yaml](10-kubevip-cm.yaml) | range `10.198.0.0-10.198.0.63` |
| [20-door.yaml](20-door.yaml) | nginx LoadBalancer, class kube-vip, pin `10.198.0.10` |
| [apply.sh](apply.sh) | cluster, attach (`--no-recreate`), push, kube-vip, door, node return route, VM route + `DOCKER-USER` accept, dashboard, MD5 |
| [check.sh](check.sh) | 7 rows; exit = FAIL count; the MD5 row runs a real negative control |
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

The Mac route is the operator's. Its gateway is the profile's own
vzNAT address — `colima list` → `ADDRESS`, `192.168.64.4` on this
Mac (`192.168.64.3` belongs to the `md5lab` profile). Apply and
check print the line with the address they read. A profile created
before `--network-address` was in the up script has no address at
all; they then print the `colima stop`/`colima start
--network-address` that adds one instead of a route that cannot
work.

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

## What was recorded

Recorded from apply `2026-09-21T00:35:36Z`.

### 1. Create the cluster

```bash
scripts/eg-colima-up.sh
```

Recorded:

```text
=== eg-colima-up.sh start 2026-09-21T00:35:37Z cluster=eg-poc1-colima ctx=colima-bgp-fabric ===
=== kindnet + kube-proxy iptables; no Cilium; no Envoy Gateway ===
subnet=172.20.0.0/16 ip-range=172.20.0.0/17 gateway=172.20.0.1
registry kind-registry already on kind-eg-colima at 172.20.0.2
catalog (in-container): {"repositories":["door","kube-vip","kube-vip-cloud-provider"]}
eg-poc1-colima-control-plane   Ready    control-plane   35s   v1.36.4   172.20.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
eg-poc1-colima-worker          Ready    <none>          22s   v1.36.4   172.20.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
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
leaf1 kind-eg-colima=172.20.254.11 leaf2 kind-eg-colima=172.20.254.12
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
rollout-to-wait: 3s md5_on_speaker=1
*172.20.0.3     4      65021         2         3       29    0    0 00:00:01            0        0 N/A
*172.20.0.4     4      65021         2         3       29    0    0 00:00:02            0        0 N/A
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
door Service ingress=10.198.0.10 after 1s
both leaves have a node path for 10.198.0.10/32 after 1s
    172.20.0.3 from 172.20.0.3 (172.20.0.3)
      Origin IGP, valid, external, multipath, best (Router ID)
    172.20.0.4 from 172.20.0.4 (172.20.0.4)
      Origin IGP, valid, external, multipath
```

### 6. Add the node return route

```bash
docker --context colima-bgp-fabric exec \
  eg-poc1-colima-worker ip route show 10.200.0.0/16
```

Recorded:

```text
eg-poc1-colima-worker 10.200.0.0/16 via 172.20.254.11 dev eth0
eg-poc1-colima-control-plane 10.200.0.0/16 via 172.20.254.11 dev eth0
```

### 7. Reach the door from client0

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T client0 curl -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 10 http://10.198.0.10/
```

Recorded:

```text
10.198.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10 uid 0
client0 http://10.198.0.10/ → 200 curl_rc=0
```

### 8. Open the VM's forward path and print the Mac's route

The VM routes the VIP block to leaf1 and accepts, in `DOCKER-USER`,
traffic toward the node-LAN bridge for that block. Without the
accept, Docker 29's `FORWARD` policy (`DROP`) discards anything
that enters from outside a docker bridge — measured with a
throwaway netns in the VM standing in for the Mac: `curl_rc=28`
with the route alone, `200` with the rule.

```bash
colima ssh --profile bgp-fabric -- sudo sh -c \
  'ip route show 10.198.0.0/24 && iptables -S DOCKER-USER'
```

Recorded:

```text
VM:  ip route replace 10.198.0.0/24 via 172.20.254.11
VM:  iptables -I DOCKER-USER -d 10.198.0.0/24 -o br-fde14ce0c6b3 -j ACCEPT
10.198.0.0/24 via 172.20.254.11 dev br-fde14ce0c6b3
-A DOCKER-USER -d 10.198.0.0/24 -o br-fde14ce0c6b3 -j ACCEPT
VM route + DOCKER-USER accept installed
Mac: sudo route -n add -net 10.198.0.0/24 192.168.64.4
Mac route in place:
mac http://10.198.0.10/ → 200 curl_rc=0
```

### 9. Read the dashboard

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Recorded:

```text
routers 4/4 · fabric sessions 6/6 · server sessions 4/4 · external 2
  172.20.0.3 asn=65021 addr=172.20.0.3
  172.20.0.4 asn=65021 addr=172.20.0.4
routers=4/4 sessions=6/6 external=2
screenshot written after 1.8 s; chrome_rc=0
```

### 10. Prove TCP MD5 on the SERVERS sessions

The counters are per network namespace, so they are read in
leaf1's — the VM's root namespace says nothing about a container's
sessions.

```bash
docker --context colima-bgp-fabric run --rm \
  --net container:bgp-fabric-colima-leaf1-1 nicolaka/netshoot:v0.16 \
  sh -c 'nstat -az | grep -E "TcpExtTCPMD5"'
```

Recorded:

```text
20 packets received by filter
0 packets dropped by kernel
```

```text
    172.20.254.11.179 > 172.20.0.3.42225: Flags [P.], cksum 0x5679 (incorrect -> 0x9409), seq 4268065406:4268065425, ack 4080745412, win 502, options [nop,nop,md5 shared secret not supplied with -M, can't check - f95b85146f813c464b0351d2cdb370fd], length 19: BGP
```

```text
TcpExtTCPMD5NotFound            0                  0.0
TcpExtTCPMD5Unexpected          0                  0.0
TcpExtTCPMD5Failure             0                  0.0
```

## Checks

Check output at `2026-09-21T00:36:14Z`:

```text
== demo 54c — kind cluster in Colima, kube-vip BGP to the fabric
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   two nodes in 172.20.0.0/17 on kind-eg-colima                           172.20.0.4 172.20.0.3                                eg-colima-up — InternalIP in the lower /17
  PASS   leaves show two SERVERS sessions each (one per node)                   4/4 Established (172.20.0.4 172.20.0.3)              both leaves × both nodes — JSON state == Established
  PASS   door 10.198.0.10/32 in each leaf with a node next hop                  leaf1:nh=172.20.0.3,172.20.0.4 leaf2:nh=172.20.0.3,172.20.0.4  EG-POC1-VIPS + as-path 65021 — node in 172.20.0.0/17
  PASS   client0 reaches the door                                               http_code=200                                        client0 → edge → spine → leaf → node → 10.198.0.10
  Mac: sudo route -n add -net 10.198.0.0/24 192.168.64.4
  Mac: sudo route -n delete -net 10.98.0.0/24
  PASS   Mac reaches the door over 192.168.64.4                                 route in place http_code=200                         operator sudo; script never runs it
  PASS   dashboard server sessions and external peers                           server=4/4 external=2 nodes=172.20.0.4 172.20.0.3    /api/state — server 4/4 (both nodes × both leaves), external=2
  PASS   SERVERS MD5 on the wire (signed) + negative control                    md5-option packets=20; wrong key on leaf1: 0/2 up in 10/10 samples, MD5Failure +14; restored in 9s peer-group key wrong → both node sessions stay down, leaf's TCPMD5Failure climbs; key back → both up

demo 54c check: 0 FAIL
```

## What is deliberately not here

- Envoy Gateway, HTTPRoute, GRPCRoute, cert-manager.
- Cilium. kindnet and kube-proxy stay on.
- kind load. Images go through the local registry.
- A `sudo` on the Mac from any script. The Mac route is printed;
  the operator runs it. (`colima ssh -- sudo` inside the VM is
  the VM's own passwordless sudo, for the VM's route and rule.)
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

The first check after that path (`2026-09-20T23:45:35Z`) ran a
negative control that could not work: `neighbor <node> password …`
on a listen-range peer. FRR answers `% Operation not allowed on a
dynamic neighbor` and configures nothing; the `clear ip bgp` that
followed dropped and re-established the session in 6 s
(`23:45:47 Established→Idle`, `23:45:53 Idle→Established` in the
dashboard's events), so the row proved only that a clear clears.
The control now changes the SERVERS peer-group key on leaf1: both
node sessions must stay down for a 10 s hold window while the
leaf's own `TcpExtTCPMD5Failure` climbs, and both must come back
when the key is restored. Measured on the live lab before the row
was rewritten: wrong key on leaf2 → both sessions absent for 31 s,
`TcpExtTCPMD5Failure` 0 → 27, signed SYNs arriving with no
SYN-ACK, leaf1 untouched at 2/2; key back → both Established in
2 s.

Until `2026-09-21T00:00Z` the profile ran without
`--network-address`: `colima list` showed no `ADDRESS`, the VM had
only Lima's user-mode `192.168.5.3`, and the pages printed
`192.168.64.3` — which is the `md5lab` profile's address, not this
VM's. `colima stop` and `colima start --network-address
--activate=false` gave the VM `192.168.64.4` on `col0` (the Mac
pings it, 1.5 ms); the fabric and this demo were re-applied, and
Docker's IPAM re-addressed the nodes (worker `172.19.0.4`,
control-plane `.3`, registry `.2`). A throwaway netns in the VM
standing in for the Mac got `curl_rc=28` through the route alone
and `200` once `DOCKER-USER` accepted the VIP block toward the
node-LAN bridge; apply installs both. The Mac's own route is the
one step left to the operator.

The first apply on the new address space (`2026-09-21T00:34:55Z`)
created the cluster on `172.20.0.3` / `.4`, then the `/17` assert
died with `KeyError: 'KIND_EG_COLIMA_IP_RANGE'` — the range was
prefixed onto `kubectl`, not exported into the Python that reads
the node list. `eg-colima-up.sh` now exports the lib's subnet
constants before that pipe. Re-apply `2026-09-21T00:35:36Z` kept
the cluster and finished. The Mac route `10.198.0.0/24 →
192.168.64.4` was already in place; check `2026-09-21T00:36:14Z`
is 7 PASS, 0 WARN (`http_code=200` from the Mac).

## Clean up

```bash
bash demos/54-eg-poc1-kube-vip-colima/cleanup.sh
```
