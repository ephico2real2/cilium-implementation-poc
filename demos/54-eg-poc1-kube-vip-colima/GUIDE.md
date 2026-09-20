# Demo 54c — five things to try

The cluster is up and peering. Five exercises against the live
objects. Exercises 1–4 only read. Exercise 5 runs the check (the
wrong-password row changes one session, then restores it).

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- docker context `colima-bgp-fabric` is running. Scripts refuse
  `desktop-linux`.
- Optional, for a curl from the Mac:

```bash
sudo route -n add -net 10.98.0.0/24 192.168.64.3
```

## Exercises

### 1. List the nodes on the cluster LAN

The two nodes must sit in the lower `/17` of the cluster LAN.

```bash
kubectl --kubeconfig ~/.kube/config-eg-poc1-colima \
  --context kind-eg-poc1-colima get nodes -o wide
```

**Expect:** worker `172.19.0.2`, control-plane `172.19.0.3`,
kernel `6.8.0-117-generic`.

```text
eg-poc1-colima-control-plane   Ready    control-plane   10m   v1.36.4   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
eg-poc1-colima-worker          Ready    <none>          10m   v1.36.4   172.19.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic (arm64)   containerd://2.3.4
```

### 2. Show the SERVERS sessions on a leaf

Each leaf has two dynamic neighbors, one per node, AS 65021.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp summary'
```

**Expect:** `*172.19.0.2` and `*172.19.0.3` Established, one
prefix each.

```text
*172.19.0.2     4      65021        28        28       25    0    0 00:01:17            1        0 N/A
*172.19.0.3     4      65021       137       137       25    0    0 00:06:44            1        0 N/A
```

### 3. Show the door in a leaf table

The `/32` is announced from both nodes.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  -f demos/46-bgp-fabric-colima/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32'
```

**Expect:** two external multipath rows, next hops the nodes.

```text
BGP routing table entry for 10.98.0.10/32, version 25
    172.19.0.3 from 172.19.0.3 (172.19.0.3)
      Origin IGP, valid, external, multipath, best (Older Path)
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
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
  --connect-timeout 5 --max-time 10 http://10.98.0.10/
```

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

**Expect:** HTTP 200 from `client0`; two external peers.

```text
client0 http://10.98.0.10/ → 200 curl_rc=0
routers 4/4 · fabric sessions 6/6 · server sessions 4/4 · external 2
```

### 5. Run the check (changes one session, then restores it)

The MD5 row sets a wrong password on one dynamic neighbor,
clears the session, then restores. Watch the dashboard while it
runs if you want the drop.

```bash
bash demos/54-eg-poc1-kube-vip-colima/check.sh
```

**Expect:** 6 PASS, 1 WARN if the Mac route is still absent, 0
FAIL.

```text
  PASS   SERVERS MD5 on the wire (signed)                                       md5-option packets=20; Established→ABSENT; restored speaker password set; negative control restored
demo 54c check: 0 FAIL
```

## Clean up

See [README Clean up](README.md#clean-up).
