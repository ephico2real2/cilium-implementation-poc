# Demo 46 — five things to try

Five exercises against the fabric once it is up; nothing here changes
the routers except reading them.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- Docker can exec into project `bgp-fabric`.

## Exercises

### 1. Print the phase-1 dashboard

The status script is the four summaries plus a text topology with the
session states (D17).

```bash
scripts/fabric-status.sh
```

**Expect:** every fabric neighbour Established (the recorded tables).

```text
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.18     4      65100         8         9        5    0    0 00:00:03            3        5 spine
Total number of neighbors 1
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.2      4      65101         8         8        5    0    0 00:00:04            1        5 leaf1
10.200.1.10     4      65102         8         8        5    0    0 00:00:04            1        5 leaf2
10.200.1.19     4      65000         8         8        5    0    0 00:00:04            2        5 edge
Total number of neighbors 3
```

### 2. Traceroute from the outside world

From `client0` the path to leaf1's loopback is edge → spine → leaf1.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

**Expect:** the recorded hops.

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.007 ms  0.002 ms  0.006 ms
 2  10.200.1.18  0.002 ms  0.000 ms  0.002 ms
 3  10.200.255.11  0.002 ms  0.001 ms  0.001 ms
```

### 3. Read the SERVERS peer-group

The listen ranges are who may dial; 0 peers until a cluster attaches.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
```

**Expect:** the recorded group (2 listen ranges, no members, no
`ttl-security`).

Recorded (second apply):

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  Configured address-families: IPv4 Unicast;
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
```

### 4. Read what a cluster may announce

The prefix-lists are the network team's "what a cluster may say":
per-cluster `/26`s, exact `/32`s, matched with as-path.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip prefix-list'
```

**Expect:** the recorded lists.

Recorded (second apply):

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

### 5. Run the check

```bash
demos/46-bgp-fabric/check.sh
```

**Expect:** 12 PASS, 1 WARN, `demo 46 check: 0 FAIL`.

Recorded (second apply):

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
  WARN   TCP MD5 in effect on the leaves                                        leaf1:TCP_MD5SIG-refused=5 leaf2:TCP_MD5SIG-refused=5  §8 row 3 — no CONFIG_TCP_MD5SIG here: sessions run unsigned
demo 46 check: 0 FAIL
```

## Clean up

[README Clean up](README.md#clean-up).
