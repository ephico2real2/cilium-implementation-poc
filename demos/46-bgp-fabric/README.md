# Demo 46 — the BGP fabric as a lab of its own

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

Four FRR routers in docker compose — edge, spine, two leaves — on their
own bridges, attachable to any cluster lab by a compose overlay. This
demo brings the fabric up with the Envoy overlay (`kind-eg`). Tracking:
[enhancement 006](../../enhancements/006-bgp-tutorial.md) §9, issue
[#52](https://github.com/ephico2real2/cilium-implementation-poc/issues/52).

## Summary context — the enterprise case

A network team hands the platform a sheet before any cluster exists:
ASNs, peering addresses, the prefixes each cluster may announce, MD5,
timers. This lab is that sheet made real. The leaves listen on a range;
the nodes dial. RFC 8212 stays on. A cluster announcing outside its
block is rejected (prefix-list + as-path per cluster; exact `/32`s).
MD5 is configured; on this Docker VM the kernel refuses `TCP_MD5SIG`
— measured — so the lab's sessions are unauthenticated; a real fabric
enforces it. SERVERS has no GTSM: the speakers send TTL 1. The fabric
does not know Kubernetes. The path a packet takes is in the
[RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`fabric/compose.yaml`](fabric/compose.yaml) | project `bgp-fabric`: edge, spine, leaf1, leaf2, client0 |
| [`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml) | leaves on `kind-eg` at `172.19.254.11` / `.12` |
| [`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml) | leaves on `kind` at `172.18.254.11` / `.12` (written, not exercised) |
| [`fabric/frr/<router>/frr.conf`](fabric/frr/) | FRR config; password is `${FABRIC_BGP_PASSWORD}` |
| [`fabric/.env.example`](fabric/.env.example) | copy to `.env`; default `lab-bgp` |
| [`fabric/entrypoint.sh`](fabric/entrypoint.sh) | renders the password, then `docker-start` |
| [`../../scripts/fabric-up.sh`](../../scripts/fabric-up.sh) | compose up + convergence |
| [`../../scripts/fabric-down.sh`](../../scripts/fabric-down.sh) | compose down; never removes `kind` / `kind-eg` |
| [`../../scripts/fabric-status.sh`](../../scripts/fabric-status.sh) | four summaries + topology (D17) |
| [`../../scripts/fabric-vm-route.sh`](../../scripts/fabric-vm-route.sh) | prints the two Mac-path lines; `--apply` is VM only |
| [`../../scripts/fabric-bgp-summary.py`](../../scripts/fabric-bgp-summary.py) | exact `state` == `Established` |
| [`apply.sh`](apply.sh) | `fabric-up.sh eg` and the recorded tables |
| [`check.sh`](check.sh) | 13 PASS/FAIL/WARN rows; exit = FAIL count (WARN is not counted) |
| [`cleanup.sh`](cleanup.sh) | `fabric-down.sh` |
| [`NETWORK-TEAM-SHEET.md`](NETWORK-TEAM-SHEET.md) | §8 filled for both LANs |
| [`GUIDE.md`](GUIDE.md) | five read-only exercises |

## Run it

From the repo root. poc1/poc2 stay paused. The `kind-eg` network must
already exist (the Envoy lab creates it). The fabric does not create a
cluster. apply.sh calls fabric-up with the Envoy overlay.

```bash
scripts/fabric-up.sh eg
demos/46-bgp-fabric/apply.sh
demos/46-bgp-fabric/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

The apply (`2026-09-20T04:22:15Z`): fabric-up with the kind-eg overlay,
then the tables. check.sh at `2026-09-20T04:22:27Z`.

### 1. Bring the fabric up

compose up with [`compose.yaml`](fabric/compose.yaml) and
[`compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml); five containers
Healthy.

```bash
scripts/fabric-up.sh eg
```

Recorded:

```text
 Network bgp-fabric_link-leaf1-spine Created
 Network bgp-fabric_wan Created
 Network bgp-fabric_link-leaf2-spine Created
 Network bgp-fabric_link-spine-edge Created
 Container bgp-fabric-leaf1-1 Created
 Container bgp-fabric-client0-1 Created
 Container bgp-fabric-leaf2-1 Created
 Container bgp-fabric-spine-1 Created
 Container bgp-fabric-edge-1 Created
 Container bgp-fabric-leaf1-1 Started
 Container bgp-fabric-leaf2-1 Started
 Container bgp-fabric-edge-1 Started
 Container bgp-fabric-client0-1 Started
 Container bgp-fabric-spine-1 Started
 Container bgp-fabric-client0-1 Healthy
 Container bgp-fabric-spine-1 Healthy
 Container bgp-fabric-leaf1-1 Healthy
 Container bgp-fabric-edge-1 Healthy
 Container bgp-fabric-leaf2-1 Healthy
```

Recorded:

```text
NAME                   IMAGE                          COMMAND                  SERVICE   CREATED         STATUS                   PORTS
bgp-fabric-client0-1   nicolaka/netshoot:v0.16        "sh -c 'ip route rep…"   client0   8 seconds ago   Up 7 seconds (healthy)
bgp-fabric-edge-1      quay.io/frrouting/frr:10.5.3   "/sbin/tini -- /usr/…"   edge      8 seconds ago   Up 7 seconds (healthy)
bgp-fabric-leaf1-1     quay.io/frrouting/frr:10.5.3   "/sbin/tini -- /usr/…"   leaf1     8 seconds ago   Up 7 seconds (healthy)
bgp-fabric-leaf2-1     quay.io/frrouting/frr:10.5.3   "/sbin/tini -- /usr/…"   leaf2     8 seconds ago   Up 7 seconds (healthy)
bgp-fabric-spine-1     quay.io/frrouting/frr:10.5.3   "/sbin/tini -- /usr/…"   spine     8 seconds ago   Up 7 seconds (healthy)
```

### 2. Watch it converge

The four `show bgp summary json` at the first poll
(`2026-09-20T04:22:22Z`). Every fabric session Established.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf2 vtysh -c 'show bgp summary json'
```

Recorded (second apply):

```text
converged after 2 s (2 polls)
```

Recorded (edge):

```text
{
"ipv4Unicast":{
  "routerId":"10.200.255.1",
  "as":65000,
  "vrfId":0,
  "vrfName":"default",
  "tableVersion":5,
  "ribCount":9,
  "ribMemory":1152,
  "peerCount":1,
  "peerMemory":16904,
  "peers":{
    "10.200.1.18":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65000,
      "version":4,
      "msgRcvd":7,
      "msgSent":8,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875491,
      "pfxRcd":3,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"spine",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":1,
  "totalPeers":1,
  "dynamicPeers":0,
  "bestPath":{
    "multiPathRelax":"true"
  }
}
}
```

Recorded (spine):

```text
{
"ipv4Unicast":{
  "routerId":"10.200.255.2",
  "as":65100,
  "vrfId":0,
  "vrfName":"default",
  "tableVersion":5,
  "ribCount":9,
  "ribMemory":1152,
  "peerCount":3,
  "peerMemory":50712,
  "peers":{
    "10.200.1.2":{
      "hostname":"leaf1",
      "softwareVersion":"n/a",
      "remoteAs":65101,
      "localAs":65100,
      "version":4,
      "msgRcvd":7,
      "msgSent":7,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875491,
      "pfxRcd":1,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"leaf1",
      "idType":"ipv4"
    },
    "10.200.1.10":{
      "hostname":"leaf2",
      "softwareVersion":"n/a",
      "remoteAs":65102,
      "localAs":65100,
      "version":4,
      "msgRcvd":7,
      "msgSent":7,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875491,
      "pfxRcd":1,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"leaf2",
      "idType":"ipv4"
    },
    "10.200.1.19":{
      "hostname":"edge",
      "softwareVersion":"n/a",
      "remoteAs":65000,
      "localAs":65100,
      "version":4,
      "msgRcvd":7,
      "msgSent":7,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875491,
      "pfxRcd":2,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"edge",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":3,
  "totalPeers":3,
  "dynamicPeers":0,
  "bestPath":{
    "multiPathRelax":"true"
  }
}
}
```

Recorded (leaf1):

```text
{
"ipv4Unicast":{
  "routerId":"10.200.255.11",
  "as":65101,
  "vrfId":0,
  "vrfName":"default",
  "tableVersion":5,
  "ribCount":9,
  "ribMemory":1152,
  "peerCount":1,
  "peerMemory":16904,
  "peerGroupCount":1,
  "peerGroupMemory":64,
  "peers":{
    "10.200.1.3":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65101,
      "version":4,
      "msgRcvd":7,
      "msgSent":8,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875492,
      "pfxRcd":4,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"spine",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":1,
  "totalPeers":1,
  "dynamicPeers":0,
  "bestPath":{
    "multiPathRelax":"false"
  }
}
}
```

Recorded (leaf2):

```text
{
"ipv4Unicast":{
  "routerId":"10.200.255.12",
  "as":65102,
  "vrfId":0,
  "vrfName":"default",
  "tableVersion":5,
  "ribCount":9,
  "ribMemory":1152,
  "peerCount":1,
  "peerMemory":16904,
  "peerGroupCount":1,
  "peerGroupMemory":64,
  "peers":{
    "10.200.1.11":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65102,
      "version":4,
      "msgRcvd":7,
      "msgSent":8,
      "tableVersion":5,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:03",
      "peerUptimeMsec":3000,
      "peerUptimeEstablishedEpoch":1789875492,
      "pfxRcd":4,
      "pfxSnt":5,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"spine",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":1,
  "totalPeers":1,
  "dynamicPeers":0,
  "bestPath":{
    "multiPathRelax":"false"
  }
}
}
```

### 3. Read the routes

Spine and edge BGP RIB (AS paths), then the edge FIB.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip route'
```

Recorded (spine `show ip bgp`):

```text
BGP table version is 5, local router ID is 10.200.255.2, vrf id 0
Default local pref 100, local AS 65100
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.200.100.0/24  10.200.1.19              0             0 65000 i
 *>  10.200.255.1/32  10.200.1.19              0             0 65000 i
 *>  10.200.255.2/32  0.0.0.0                  0         32768 i
 *>  10.200.255.11/32 10.200.1.2               0             0 65101 i
 *>  10.200.255.12/32 10.200.1.10              0             0 65102 i
Displayed 5 routes and 5 total paths
```

Recorded (edge `show ip bgp`):

```text
BGP table version is 5, local router ID is 10.200.255.1, vrf id 0
Default local pref 100, local AS 65000
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.200.100.0/24  0.0.0.0                  0         32768 i
 *>  10.200.255.1/32  0.0.0.0                  0         32768 i
 *>  10.200.255.2/32  10.200.1.18              0             0 65100 i
 *>  10.200.255.11/32 10.200.1.18                            0 65100 65101 i
 *>  10.200.255.12/32 10.200.1.18                            0 65100 65102 i
Displayed 5 routes and 5 total paths
```

Recorded (edge `show ip route`):

```text
K>* 0.0.0.0/0 [0/0] via 10.200.1.17, eth1, weight 1, 00:00:08
C>* 10.200.1.16/29 is directly connected, eth1, weight 1, 00:00:08
L>* 10.200.1.19/32 is directly connected, eth1, weight 1, 00:00:08
C>* 10.200.100.0/24 is directly connected, eth0, weight 1, 00:00:08
L>* 10.200.100.2/32 is directly connected, eth0, weight 1, 00:00:08
L * 10.200.255.1/32 is directly connected, lo, weight 1, 00:00:08
C>* 10.200.255.1/32 is directly connected, lo, weight 1, 00:00:08
B>* 10.200.255.2/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:03
B>* 10.200.255.11/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:03
B>* 10.200.255.12/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:03
```

### 4. Walk the path from the outside world

From `client0` to leaf1's loopback: edge → spine → leaf1. Then ping
and the client's default route.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Recorded:

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.007 ms  0.002 ms  0.006 ms
 2  10.200.1.18  0.002 ms  0.000 ms  0.002 ms
 3  10.200.255.11  0.002 ms  0.001 ms  0.001 ms
```

Recorded:

```text
PING 10.200.255.11 (10.200.255.11) 56(84) bytes of data.
64 bytes from 10.200.255.11: icmp_seq=1 ttl=62 time=0.071 ms
64 bytes from 10.200.255.11: icmp_seq=2 ttl=62 time=0.143 ms
64 bytes from 10.200.255.11: icmp_seq=3 ttl=62 time=0.084 ms
--- 10.200.255.11 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2052ms
rtt min/avg/max/mdev = 0.071/0.099/0.143/0.031 ms
```

Recorded:

```text
default via 10.200.100.2 dev eth0
10.200.100.0/24 dev eth0 proto kernel scope link src 10.200.100.10
```

### 5. Touch the node LAN

leaf1 → `172.19.0.3` on-link through the overlay.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 ping -c 1 -W 2 172.19.0.3
```

Recorded:

```text
PING 172.19.0.3 (172.19.0.3): 56 data bytes
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.152 ms
--- 172.19.0.3 ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 0.152/0.152/0.152 ms
```

### 6. Read the servers' policy

SERVERS peer-group (2 listen ranges, 0 peers), prefix-lists, route-maps
on both leaves.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip prefix-list'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show route-map'
```

Recorded (second apply) (leaf1 SERVERS):

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  Configured address-families: IPv4 Unicast;
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
```

Recorded (second apply) (leaf1 prefix-lists):

```text
ZEBRA: ip prefix-list CILIUM-ANYCAST-VIPS: 1 entries
   seq 10 permit 10.99.0.192/26 ge 32 le 32
ZEBRA: ip prefix-list CILIUM-POC1-VIPS: 1 entries
   seq 10 permit 10.99.0.0/26 ge 32 le 32
ZEBRA: ip prefix-list CILIUM-POC2-VIPS: 1 entries
   seq 10 permit 10.99.0.64/26 ge 32 le 32
ZEBRA: ip prefix-list CILIUM-VIPS: 1 entries
   seq 10 permit 10.99.0.0/24 ge 32 le 32
ZEBRA: ip prefix-list COMPANY: 1 entries
   seq 10 permit 10.200.0.0/16 le 32
ZEBRA: ip prefix-list EG-ANYCAST-VIPS: 1 entries
   seq 10 permit 10.98.0.192/26 ge 32 le 32
ZEBRA: ip prefix-list EG-POC1-VIPS: 1 entries
   seq 10 permit 10.98.0.0/26 ge 32 le 32
ZEBRA: ip prefix-list EG-POC2-VIPS: 1 entries
   seq 10 permit 10.98.0.64/26 ge 32 le 32
ZEBRA: ip prefix-list EG-VIPS: 1 entries
   seq 10 permit 10.98.0.0/24 ge 32 le 32
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

Recorded (second apply) (leaf1 BGP route-maps):

```text
route-map: FABRIC-IN Invoked: 10 (0 milliseconds total) Optimization: enabled Processed Change: false
 permit, sequence 10 Invoked 10 (0 milliseconds total)
  Match clauses:
    ip address prefix-list COMPANY
route-map: LEAF-OUT Invoked: 11 (0 milliseconds total) Optimization: enabled Processed Change: false
 permit, sequence 10 Invoked 11 (0 milliseconds total)
  Match clauses:
    ip address prefix-list COMPANY
route-map: NOTHING Invoked: 0 (0 milliseconds total) Optimization: enabled Processed Change: false
 deny, sequence 10 Invoked 0 (0 milliseconds total)
route-map: SERVERS-IN Invoked: 0 (0 milliseconds total) Optimization: enabled Processed Change: false
 permit, sequence 10 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list EG-POC1-VIPS
    as-path EG-POC1
 permit, sequence 20 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list EG-POC2-VIPS
    as-path EG-POC2
 permit, sequence 30 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list EG-ANYCAST-VIPS
    as-path EG-POC1
 permit, sequence 31 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list EG-ANYCAST-VIPS
    as-path EG-POC2
 permit, sequence 40 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list CILIUM-POC1-VIPS
    as-path CILIUM-POC1
 permit, sequence 50 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list CILIUM-POC2-VIPS
    as-path CILIUM-POC2
 permit, sequence 60 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list CILIUM-ANYCAST-VIPS
    as-path CILIUM-POC1
 permit, sequence 61 Invoked 0 (0 milliseconds total)
  Match clauses:
    ip address prefix-list CILIUM-ANYCAST-VIPS
    as-path CILIUM-POC2
```

Recorded (second apply) (leaves `maximum-paths`):

```text
  PASS   ECMP maximum-paths on spine and leaves                                 maximum-paths 8                                      R5 — maximum-paths 8
```

Recorded (second apply) (leaf2 SERVERS):

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  Configured address-families: IPv4 Unicast;
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
```

## Checks

```bash
demos/46-bgp-fabric/check.sh
```

`check.sh` at `2026-09-20T04:22:27Z`: 12 PASS, 1 WARN, 0 FAIL.

Recorded (second apply):

```text
### 2026-09-20T04:22:27Z
$ demos/46-bgp-fabric/check.sh
== demo 46 — the BGP fabric (four FRR routers, Envoy overlay)
  STATUS WHAT                                                                   MEASURED                                             RULE
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

## What is deliberately not here

- No cluster peers yet: SERVERS has 2 listen ranges and 0 members.
- No dashboard. Phase 1 is [fabric-status.sh](../../scripts/fabric-status.sh)
  (D17); the Kubernetes dashboard is phase 2.
- No Mac route applied. D18 prints two lines;
  [fabric-vm-route.sh](../../scripts/fabric-vm-route.sh) `--apply` is the
  VM only.
- Cilium BGP, kube-vip BGP, MetalLB FRR-K8s — demos 47–49, 56, 57.
- A cluster. The overlay attaches to `kind-eg`; this demo does not
  create or change `eg-poc1` / `eg-poc2`.
- `compose.lan-cilium.yaml` is written; the Cilium clusters are paused.
- One fabric per Docker host: the `/29` link subnets overlap with any
  second copy. `fabric-up.sh` refuses to start when another compose
  project already owns `10.200.1.0/29`.

## Clean up

```bash
demos/46-bgp-fabric/cleanup.sh
```

cleanup.sh calls `scripts/fabric-down.sh`. The fabric's own networks
go; `kind` and `kind-eg` stay.
