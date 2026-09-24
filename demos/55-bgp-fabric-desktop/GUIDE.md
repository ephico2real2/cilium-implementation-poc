# Demo 55 — six things to try

Six exercises against the fabric once it is up. Exercises 1–5 only
read. Exercise 6 clears the spine's sessions; they return on their
own.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- Docker can exec into project `bgp-fabric`.

## Exercises

### 1. Print the status table

The status script is the four summaries plus a text topology with the
session states, then the dashboard one-liner.

```bash
scripts/fabric-status.sh
```

**Expect:** every fabric neighbour Established (the recorded tables).

```text
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.18     4      65100        10         9        7    0    0 00:00:06            5        5 spine
Total number of neighbors 1
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.2      4      65101        10        10        9    0    0 00:00:07            3        7 leaf1
10.200.1.10     4      65102        10        11        9    0    0 00:00:06            3        7 leaf2
10.200.1.19     4      65000         9        11        9    0    0 00:00:06            2        7 edge
Total number of neighbors 3
```

The same apply's dashboard line:

```text
routers=4/4 sessions=6/6 external=2
```

### 2. Traceroute from the outside world

From `client0` the path to leaf1's loopback is edge → spine → leaf1.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

**Expect:** the recorded hops.

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.009 ms  0.005 ms  0.003 ms
 2  10.200.1.18  0.002 ms  0.004 ms  0.004 ms
 3  10.200.255.11  0.001 ms  0.004 ms  0.002 ms
```

### 3. Read the SERVERS peer-group

The listen ranges are who may dial; this apply already has kube-vip
members.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
```

**Expect:** the recorded group (2 listen ranges, members Established,
no `ttl-security`).

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  Configured address-families: IPv4 Unicast;
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
  Peer-group members:
    172.19.0.2 (dynamic) Established
    172.19.0.3 (dynamic) Established
```

### 4. Read what a cluster may announce

The prefix-lists are the network team's "what a cluster may say":
per-cluster `/26`s, exact `/32`s, matched with as-path.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip prefix-list'
```

**Expect:** the recorded lists.

```text
BGP: ip prefix-list CILIUM-ANYCAST-VIPS: 1 entries
   seq 10 permit 10.99.0.192/26 ge 32 le 32
BGP: ip prefix-list CILIUM-POC1-VIPS: 1 entries
   seq 10 permit 10.99.0.0/26 ge 32 le 32
BGP: ip prefix-list CILIUM-POC2-VIPS: 1 entries
   seq 10 permit 10.99.0.64/26 ge 32 le 32
BGP: ip prefix-list CILIUM-VIPS: 1 entries
   seq 10 permit 10.99.0.0/24 ge 32 le 32
BGP: ip prefix-list COMPANY: 1 entries
   seq 10 permit 10.200.0.0/16 le 32
BGP: ip prefix-list EG-ANYCAST-VIPS: 1 entries
   seq 10 permit 10.98.0.192/26 ge 32 le 32
BGP: ip prefix-list EG-POC1-VIPS: 1 entries
   seq 10 permit 10.98.0.0/26 ge 32 le 32
BGP: ip prefix-list EG-POC2-VIPS: 1 entries
   seq 10 permit 10.98.0.64/26 ge 32 le 32
BGP: ip prefix-list EG-VIPS: 1 entries
   seq 10 permit 10.98.0.0/24 ge 32 le 32
```

### 5. Follow an announced address across the fabric

A cluster announced `10.98.0.46/32`. Ask each router how it learned it —
the as-path grows by one AS at every hop.

```bash
docker compose -p bgp-fabric -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp ipv4 unicast 10.98.0.46/32'
```

**Expect:** two paths, both as-path `65021`, one from each node.

```text
BGP routing table entry for 10.98.0.46/32
Paths: (2 available, best #1, table default)
  65021
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
      Origin IGP, valid, external, multipath, best (Router ID)
  65021
    172.19.0.3 from 172.19.0.3 (172.19.0.3)
```

```bash
docker compose -p bgp-fabric -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T spine ip route show 10.98.0.46
```

**Expect:** the kernel route, with a nexthop through each leaf.

```text
10.98.0.46 nhid 25 proto bgp metric 20
 nexthop via 10.200.1.2 dev eth1 weight 1
 nexthop via 10.200.1.10 dev eth2 weight 1
```

### 6. Run the check

```bash
demos/55-bgp-fabric-desktop/check.sh
```

**Expect:** 16 rows, 15 PASS, 1 WARN, `demo 46 check: 0 FAIL`. Row 16
probes all four management addresses (`client0_rc=28,28,28,28`).

```text
  PASS   four routers running                                                   running=4/4                                          R1 — edge spine leaf1 leaf2 running
  PASS   six fabric sessions Established                                        6/6 Established                                      R1 — leaf1–spine, leaf2–spine, spine–edge, both directions
  PASS   client0 ping 10.200.255.1                                              rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.2                                              rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.11                                             rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.12                                             rc=0                                                 R1 — loopback reachable from client0
  PASS   10.200.100.0/24 in leaf1 via spine                                     via 10.200.1.3                                       R1 — wan learned via 10.200.1.3
  PASS   ECMP maximum-paths on spine and leaves                                 maximum-paths 8                                      R5 — maximum-paths 8
  PASS   SERVERS listen both /17s on both leaves                                leaf1+leaf2                                          D5 / §9.1 — listen range on the peer-group
  PASS   per-cluster VIP prefix-lists                                           EG/CILIUM POC1/POC2/ANYCAST ge 32 le 32              R8 — prefix-list + as-path per cluster
  PASS   leaves on kind-eg 172.19.254.11/.12                                    leaf1=172.19.254.11 leaf2=172.19.254.12              §9.1 — 172.19.254.11/.12
  PASS   RFC 8212 in effect                                                     traditional profile, ebgp-requires-policy on         §8 row 5 — traditional defaults, explicit route-maps
  WARN   TCP MD5 in effect on the leaves                                        leaf1:TCP_MD5SIG-refused=9 leaf2:TCP_MD5SIG-refused=9  §8 row 3 — no CONFIG_TCP_MD5SIG here: sessions run unsigned
  PASS   dashboard reachable, 4/4 routers polled                                routers=4/4 sessions=6/6 external=2                  D8 — /api/state from 127.0.0.1:8088
  PASS   dashboard sessions agree with vtysh                                    6/6 = 6/6                                            D17 — state Established matches fabric-bgp-summary
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
demo 46 check: 0 FAIL
```

### 7. Open the dashboard and clear the spine (changes state)

The page is at `http://127.0.0.1:8088/`. Then clear the spine; the
sessions return on their own.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

**Expect:** the dashboard shows the drop, then the sessions come back.
The 1.49 s is the loop's notice; the event window is 2.002 s.

```text
dashboard showed the drop after 1.49 s
dashboard confirmed recovery after 0.67 s (polled after the screenshots)
spine recovery: first Idle 2026-09-20T19:29:23.904Z last Established 2026-09-20T19:29:25.906Z recovered=yes window=2.002 s
```

## Clean up

[README Clean up](README.md#clean-up).
