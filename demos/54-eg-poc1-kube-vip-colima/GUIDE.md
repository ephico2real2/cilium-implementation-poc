# Demo 54c — five things to try

The cluster is up and peering. Five exercises against the live
objects. Exercises 1–4 only read. Exercise 5 runs the check, whose
MD5 row takes leaf1's two node sessions down for about fifteen
seconds and brings them back.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- docker context `colima-bgp-fabric` is running. Scripts refuse
  `desktop-linux`.
- Optional, for a curl from the Mac (the gateway is this profile's
  vzNAT address — `colima list` → `ADDRESS`):

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

## Exercises

### 1. List the nodes on the cluster LAN

The two nodes must sit in the lower `/17` of the cluster LAN.

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima get nodes -o wide
```

**Expect:** control-plane `172.20.0.3`, worker `172.20.0.4`,
kernel `6.8.0-117-generic`.

```text
eg-poc1-colima-control-plane   Ready    control-plane   35s   v1.36.4   172.20.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
eg-poc1-colima-worker          Ready    <none>          22s   v1.36.4   172.20.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
```

### 2. Show the SERVERS sessions on a leaf

Each leaf has two dynamic neighbors, one per node, AS 65021.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp summary'
```

**Expect:** `*172.20.0.3` and `*172.20.0.4` Established. At
peer-up the prefix count is 0; the door `/32` arrives in the
next exercise.

```text
*172.20.0.3     4      65021         2         3       29    0    0 00:00:01            0        0 N/A
*172.20.0.4     4      65021         2         3       29    0    0 00:00:02            0        0 N/A
```

### 3. Show the door in a leaf table

The `/32` is announced from both nodes; the spine echoes leaf2's
copy back as a third, longer path.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip bgp 10.198.0.10/32'
```

**Expect:** two external multipath rows with the nodes as next
hops (leaf2 also holds the spine's echo as a third path).

```text
BGP routing table entry for 10.198.0.10/32, version 30
Paths: (2 available, best #1, table default)
    172.20.0.3 from 172.20.0.3 (172.20.0.3)
      Origin IGP, valid, external, multipath, best (Router ID)
    172.20.0.4 from 172.20.0.4 (172.20.0.4)
      Origin IGP, valid, external, multipath
```

### 4. Reach the door from client0 and read the dashboard

`client0` is the outside world. The dashboard is the answer to
"I don't see any connection on 8098".

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T client0 curl -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 10 http://10.198.0.10/
```

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

**Expect:** HTTP 200 from `client0`; two external peers.

```text
client0 http://10.198.0.10/ → 200 curl_rc=0
routers 4/4 · fabric sessions 6/6 · server sessions 4/4 · external 2
```

### 5. Run the check (the negative control)

The MD5 row puts a wrong key on leaf1's SERVERS peer-group — the
only place a listen-range peer's key can be set; FRR answers
`% Operation not allowed on a dynamic neighbor` to a per-neighbour
command — then expects both node sessions to stay down for ten
seconds while leaf1's own `TcpExtTCPMD5Failure` climbs, restores
the key, and expects both back. Watch the dashboard's events while
it runs: leaf1's two sessions drop and return; leaf2's never move.

```bash
bash demos/54-eg-poc1-kube-vip-colima/check.sh
```

**Expect:** 7 PASS, 0 WARN, 0 FAIL when the Mac route is in
place (`http_code=200` from the Mac).

```text
  PASS   SERVERS MD5 on the wire (signed) + negative control                    md5-option packets=20; wrong key on leaf1: 0/2 up in 10/10 samples, MD5Failure +14; restored in 9s peer-group key wrong → both node sessions stay down, leaf's TCPMD5Failure climbs; key back → both up
demo 54c check: 0 FAIL
```

## Clean up

See [README Clean up](README.md#clean-up).
