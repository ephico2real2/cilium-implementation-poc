# Demo 46 — the BGP fabric as a lab of its own

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

The fabric, the dashboard and the router agent are not in this repository: they live in [ephico2real2/bgp-fabric](https://github.com/ephico2real2/bgp-fabric) and this lab builds them at a pinned commit ([`scripts/bgp-fabric.env`](../../scripts/bgp-fabric.env)).

Four FRR routers in docker compose — edge, spine, two leaves — on their
own bridges, attachable to any cluster lab by a compose overlay. A
fifth compose service, `bgp-dashboard` on `127.0.0.1:8088`, reads a
show-only agent on the out-of-band `mgmt` LAN. This demo brings the
fabric up with the Envoy overlay (`kind-eg`). Tracking:
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
| [`fabric/compose.yaml`](fabric/compose.yaml) | project `bgp-fabric`: edge, spine, leaf1, leaf2, client0, dashboard at `10.200.200.100`; `mgmt` `10.200.200.0/24` |
| [`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml) | leaves on `kind-eg` at `172.19.254.11` / `.12` |
| [`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml) | leaves on `kind` at `172.18.254.11` / `.12` (written, not exercised) |
| [`fabric/frr/<router>/frr.conf`](fabric/frr/) | FRR config; password is `${FABRIC_BGP_PASSWORD}` |
| [`fabric/.env.example`](fabric/.env.example) | copy to `.env`; default `lab-bgp` |
| [`fabric/entrypoint.sh`](fabric/entrypoint.sh) | renders the password, FORWARD drop on mgmt, INPUT accept on mgmt/`lo` and drop elsewhere, then `docker-start` |
| [`../../scripts/bgp-fabric.env`](../../scripts/bgp-fabric.env) | which bgp-fabric commit this lab builds against — the agent and the dashboard come from there |
| [`../../scripts/bgp-fabric-fetch.sh`](../../scripts/bgp-fabric-fetch.sh) | puts that commit on disk under `vendor/`; `BGP_FABRIC_DIR` overrides it |
| [`../../scripts/fabric-up.sh`](../../scripts/fabric-up.sh) | builds `frr-agent:local` and `bgp-dashboard:local` if absent; compose up + convergence |
| [`../../scripts/fabric-down.sh`](../../scripts/fabric-down.sh) | compose down; never removes `kind` / `kind-eg` |
| [`../../scripts/fabric-status.sh`](../../scripts/fabric-status.sh) | four summaries + topology + dashboard one-liner |
| [`../../scripts/fabric-vm-route.sh`](../../scripts/fabric-vm-route.sh) | prints the two Mac-path lines; `--apply` is VM only |
| [`../../scripts/fabric-bgp-summary.py`](../../scripts/fabric-bgp-summary.py) | exact `state` == `Established` |
| [`../../scripts/fabric-dashboard-state.py`](../../scripts/fabric-dashboard-state.py) | `routers=N/N sessions=N/N external=N` |
| [`../../demos/shared/browser-shot.sh`](../../demos/shared/browser-shot.sh) | headless Chrome shot |
| [`apply.sh`](apply.sh) | `fabric-up.sh eg` and the recorded tables (steps 10–12: dashboard) |
| [`check.sh`](check.sh) | 16 rows; exit = FAIL count (WARN is not counted) |
| [`cleanup.sh`](cleanup.sh) | `fabric-down.sh` |
| [`NETWORK-TEAM-SHEET.md`](NETWORK-TEAM-SHEET.md) | §8 filled for both LANs |
| [`GUIDE.md`](GUIDE.md) | six exercises (one changes state) |
| [`../../tests/fabric-mgmt-oob.sh`](../../tests/fabric-mgmt-oob.sh) | mgmt is out of band |
| [`../../tests/fabric-dashboard-unit.sh`](../../tests/fabric-dashboard-unit.sh) | Go tests for agent and dashboard |
| [`../../tests/fabric-agent-allowlist.sh`](../../tests/fabric-agent-allowlist.sh) | allow-list only |
| [`../../tests/fabric-agent-mgmt-input.sh`](../../tests/fabric-agent-mgmt-input.sh) | agents answer mgmt only; data plane cannot read them |

## Run it

From the repo root. poc1/poc2 stay paused. The `kind-eg` network must
already exist (the Envoy lab creates it). The fabric does not create a
cluster. apply.sh calls fabric-up with the Envoy overlay. The dashboard
is at `http://127.0.0.1:8088/`.

```bash
scripts/fabric-up.sh eg
demos/46-bgp-fabric/apply.sh
demos/46-bgp-fabric/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

The apply (`2026-09-20T19:29:04Z`): fabric-up with the kind-eg overlay,
then the tables and the dashboard. check.sh at `2026-09-20T19:29:40Z`.
The routers run `frr-agent:local` (built on
`quay.io/frrouting/frr:10.7.1`).

### 1. Bring the fabric up

compose up with [`compose.yaml`](fabric/compose.yaml) and
[`compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml); six containers
Healthy.

```bash
scripts/fabric-up.sh eg
```

Recorded:

```text
 Network bgp-fabric_mgmt Created
 Network bgp-fabric_wan Created
 Network bgp-fabric_link-leaf2-spine Created
 Network bgp-fabric_link-leaf1-spine Created
 Network bgp-fabric_link-spine-edge Created
 Container bgp-fabric-leaf1-1 Created
 Container bgp-fabric-client0-1 Created
 Container bgp-fabric-leaf2-1 Created
 Container bgp-fabric-spine-1 Created
 Container bgp-fabric-edge-1 Created
 Container bgp-fabric-dashboard-1 Created
 Container bgp-fabric-leaf1-1 Started
 Container bgp-fabric-leaf2-1 Started
 Container bgp-fabric-edge-1 Started
 Container bgp-fabric-client0-1 Started
 Container bgp-fabric-spine-1 Started
 Container bgp-fabric-dashboard-1 Started
 Container bgp-fabric-client0-1 Healthy
 Container bgp-fabric-spine-1 Healthy
 Container bgp-fabric-leaf1-1 Healthy
 Container bgp-fabric-edge-1 Healthy
 Container bgp-fabric-leaf2-1 Healthy
 Container bgp-fabric-dashboard-1 Healthy
```

Recorded:

```text
NAME                     IMAGE                     COMMAND                  SERVICE     CREATED          STATUS                    PORTS
bgp-fabric-client0-1     nicolaka/netshoot:v0.16   "sh -c 'ip route rep…"   client0     11 seconds ago   Up 11 seconds (healthy)
bgp-fabric-dashboard-1   bgp-dashboard:local       "/dashboard"             dashboard   11 seconds ago   Up 6 seconds (healthy)    127.0.0.1:8088->8080/tcp
bgp-fabric-edge-1        frr-agent:local           "/sbin/tini -- /usr/…"   edge        11 seconds ago   Up 10 seconds (healthy)
bgp-fabric-leaf1-1       frr-agent:local           "/sbin/tini -- /usr/…"   leaf1       11 seconds ago   Up 11 seconds (healthy)
bgp-fabric-leaf2-1       frr-agent:local           "/sbin/tini -- /usr/…"   leaf2       11 seconds ago   Up 10 seconds (healthy)
bgp-fabric-spine-1       frr-agent:local           "/sbin/tini -- /usr/…"   spine       11 seconds ago   Up 11 seconds (healthy)
```

Recorded:

```text
converged after 0 s (1 polls)
dashboard ready after 0 s (routers=4/4 sessions=6/6 external=2)
```

### 2. Watch it converge

The four `show bgp summary json` at the first poll
(`2026-09-20T19:29:15Z`). Every fabric session Established.

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

Recorded:

```text
converged after 0 s (1 polls)
```

Recorded (edge):

```text
{
"ipv4Unicast":{
  "routerId":"10.200.255.1",
  "as":65000,
  "vrfId":0,
  "vrfName":"default",
  "tableVersion":7,
  "ribCount":7,
  "ribMemory":1120,
  "peerCount":1,
  "peerMemory":23528,
  "peers":{
    "10.200.1.18":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65000,
      "version":4,
      "msgRcvd":9,
      "msgSent":8,
      "tableVersion":7,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:06",
      "peerUptimeMsec":6000,
      "peerUptimeEstablishedEpoch":1789932549,
      "pfxRcd":5,
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
  "tableVersion":9,
  "ribCount":7,
  "ribMemory":1120,
  "peerCount":3,
  "peerMemory":70584,
  "peers":{
    "10.200.1.2":{
      "hostname":"leaf1",
      "softwareVersion":"n/a",
      "remoteAs":65101,
      "localAs":65100,
      "version":4,
      "msgRcvd":10,
      "msgSent":10,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:07",
      "peerUptimeMsec":7000,
      "peerUptimeEstablishedEpoch":1789932548,
      "pfxRcd":3,
      "pfxSnt":7,
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
      "msgRcvd":10,
      "msgSent":11,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:06",
      "peerUptimeMsec":6000,
      "peerUptimeEstablishedEpoch":1789932549,
      "pfxRcd":3,
      "pfxSnt":7,
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
      "msgRcvd":8,
      "msgSent":11,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:06",
      "peerUptimeMsec":6000,
      "peerUptimeEstablishedEpoch":1789932549,
      "pfxRcd":2,
      "pfxSnt":7,
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
  "tableVersion":9,
  "ribCount":9,
  "ribMemory":1440,
  "peerCount":3,
  "peerMemory":70584,
  "peerGroupCount":1,
  "peerGroupMemory":72,
  "peers":{
    "172.19.0.2":{
      "dynamicPeer":true,
      "hostname":"eg-poc1-control-plane",
      "softwareVersion":"n/a",
      "remoteAs":65021,
      "localAs":65101,
      "version":4,
      "msgRcvd":5,
      "msgSent":5,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:08",
      "peerUptimeMsec":8000,
      "peerUptimeEstablishedEpoch":1789932548,
      "pfxRcd":2,
      "pfxSnt":0,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "idType":"ipv4"
    },
    "172.19.0.3":{
      "dynamicPeer":true,
      "hostname":"eg-poc1-worker",
      "softwareVersion":"n/a",
      "remoteAs":65021,
      "localAs":65101,
      "version":4,
      "msgRcvd":5,
      "msgSent":5,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:08",
      "peerUptimeMsec":8000,
      "peerUptimeEstablishedEpoch":1789932548,
      "pfxRcd":2,
      "pfxSnt":0,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "idType":"ipv4"
    },
    "10.200.1.3":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65101,
      "version":4,
      "msgRcvd":10,
      "msgSent":11,
      "tableVersion":9,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:07",
      "peerUptimeMsec":7000,
      "peerUptimeEstablishedEpoch":1789932549,
      "pfxRcd":4,
      "pfxSnt":7,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"spine",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":3,
  "totalPeers":3,
  "dynamicPeers":2,
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
  "tableVersion":11,
  "ribCount":9,
  "ribMemory":1440,
  "peerCount":3,
  "peerMemory":70584,
  "peerGroupCount":1,
  "peerGroupMemory":72,
  "peers":{
    "172.19.0.2":{
      "dynamicPeer":true,
      "hostname":"eg-poc1-control-plane",
      "softwareVersion":"n/a",
      "remoteAs":65021,
      "localAs":65102,
      "version":4,
      "msgRcvd":5,
      "msgSent":5,
      "tableVersion":11,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:08",
      "peerUptimeMsec":8000,
      "peerUptimeEstablishedEpoch":1789932548,
      "pfxRcd":2,
      "pfxSnt":0,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "idType":"ipv4"
    },
    "172.19.0.3":{
      "dynamicPeer":true,
      "hostname":"eg-poc1-worker",
      "softwareVersion":"n/a",
      "remoteAs":65021,
      "localAs":65102,
      "version":4,
      "msgRcvd":5,
      "msgSent":5,
      "tableVersion":11,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:08",
      "peerUptimeMsec":8000,
      "peerUptimeEstablishedEpoch":1789932548,
      "pfxRcd":2,
      "pfxSnt":0,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "idType":"ipv4"
    },
    "10.200.1.11":{
      "hostname":"spine",
      "softwareVersion":"n/a",
      "remoteAs":65100,
      "localAs":65102,
      "version":4,
      "msgRcvd":10,
      "msgSent":10,
      "tableVersion":11,
      "outq":0,
      "inq":0,
      "peerUptime":"00:00:06",
      "peerUptimeMsec":6000,
      "peerUptimeEstablishedEpoch":1789932550,
      "pfxRcd":6,
      "pfxSnt":7,
      "state":"Established",
      "peerState":"OK",
      "connectionsEstablished":1,
      "connectionsDropped":0,
      "desc":"spine",
      "idType":"ipv4"
    }
  },
  "failedPeers":0,
  "displayedPeers":3,
  "totalPeers":3,
  "dynamicPeers":2,
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
BGP table version is 9, local router ID is 10.200.255.2, vrf id 0
Default local pref 100, local AS 65100
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.98.0.10/32    10.200.1.2                             0 65101 65021 i
 *=                   10.200.1.10                            0 65102 65021 i
 *>  10.98.0.11/32    10.200.1.2                             0 65101 65021 i
 *=                   10.200.1.10                            0 65102 65021 i
 *>  10.200.100.0/24  10.200.1.19              0             0 65000 i
 *>  10.200.255.1/32  10.200.1.19              0             0 65000 i
 *>  10.200.255.2/32  0.0.0.0                  0         32768 i
 *>  10.200.255.11/32 10.200.1.2               0             0 65101 i
 *>  10.200.255.12/32 10.200.1.10              0             0 65102 i
Displayed 7 routes and 9 total paths
```

Recorded (edge `show ip bgp`):

```text
BGP table version is 7, local router ID is 10.200.255.1, vrf id 0
Default local pref 100, local AS 65000
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.98.0.10/32    10.200.1.18                            0 65100 65101 65021 i
 *>  10.98.0.11/32    10.200.1.18                            0 65100 65101 65021 i
 *>  10.200.100.0/24  0.0.0.0                  0         32768 i
 *>  10.200.255.1/32  0.0.0.0                  0         32768 i
 *>  10.200.255.2/32  10.200.1.18              0             0 65100 i
 *>  10.200.255.11/32 10.200.1.18                            0 65100 65101 i
 *>  10.200.255.12/32 10.200.1.18                            0 65100 65102 i
Displayed 7 routes and 7 total paths
```

Recorded (edge `show ip route`):

```text
K>* 0.0.0.0/0 [0/0] via 10.200.1.17, eth1, weight 1, 00:00:11
B>* 10.98.0.10/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
B>* 10.98.0.11/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
C>* 10.200.1.16/29 is directly connected, eth1, weight 1, 00:00:11
L>* 10.200.1.19/32 is directly connected, eth1, weight 1, 00:00:11
C>* 10.200.100.0/24 is directly connected, eth0, weight 1, 00:00:11
L>* 10.200.100.2/32 is directly connected, eth0, weight 1, 00:00:11
C>* 10.200.200.0/24 is directly connected, eth2, weight 1, 00:00:11
L>* 10.200.200.1/32 is directly connected, eth2, weight 1, 00:00:11
L * 10.200.255.1/32 is directly connected, lo, weight 1, 00:00:11
C>* 10.200.255.1/32 is directly connected, lo, weight 1, 00:00:11
B>* 10.200.255.2/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
B>* 10.200.255.11/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
B>* 10.200.255.12/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
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
 1  10.200.100.2  0.009 ms  0.005 ms  0.003 ms
 2  10.200.1.18  0.002 ms  0.004 ms  0.004 ms
 3  10.200.255.11  0.001 ms  0.004 ms  0.002 ms
```

Recorded:

```text
PING 10.200.255.11 (10.200.255.11) 56(84) bytes of data.
64 bytes from 10.200.255.11: icmp_seq=1 ttl=62 time=0.106 ms
64 bytes from 10.200.255.11: icmp_seq=2 ttl=62 time=0.140 ms
64 bytes from 10.200.255.11: icmp_seq=3 ttl=62 time=0.168 ms
--- 10.200.255.11 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2064ms
rtt min/avg/max/mdev = 0.106/0.138/0.168/0.025 ms
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
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.146 ms
--- 172.19.0.3 ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 0.146/0.146/0.146 ms
```

### 6. Read the servers' policy

SERVERS peer-group (2 listen ranges; kube-vip members Established),
prefix-lists, route-maps on both leaves.

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

Recorded (leaf1 SERVERS):

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

Recorded (leaf1 prefix-lists):

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

Recorded (leaf1 BGP route-maps):

```text
route-map: FABRIC-IN Invoked: 4 (0 milliseconds total) Optimization: enabled Processed Change: false
route-map: LEAF-OUT Invoked: 13 (0 milliseconds total) Optimization: enabled Processed Change: false
route-map: NOTHING Invoked: 14 (0 milliseconds total) Optimization: enabled Processed Change: false
route-map: SERVERS-IN Invoked: 12 (0 milliseconds total) Optimization: enabled Processed Change: false
    ip address prefix-list EG-POC1-VIPS
    as-path EG-POC1
    ip address prefix-list EG-POC2-VIPS
    as-path EG-POC2
```

Recorded (leaves `maximum-paths`):

```text
  PASS   ECMP maximum-paths on spine and leaves                                 maximum-paths 8                                      R5 — maximum-paths 8
```

Recorded (leaf2 SERVERS):

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

### 7. Read the dashboard's state

```bash
curl -sS --max-time 5 http://127.0.0.1:8088/api/state
curl -fsS --max-time 5 http://127.0.0.1:8088/api/state | python3 scripts/fabric-dashboard-state.py
```

Recorded (`/api/state` head):

```text
{
    "ts": "2026-09-20T19:29:19.905Z",
    "poll": "2s",
    "routers": [
        {
            "name": "edge",
            "url": "http://10.200.200.1:8080",
            "asn": 65000,
            "routerId": "10.200.255.1",
            "reachable": true
        },
        {
            "name": "spine",
            "url": "http://10.200.200.2:8080",
            "asn": 65100,
            "routerId": "10.200.255.2",
            "reachable": true
        },
        {
            "name": "leaf1",
            "url": "http://10.200.200.11:8080",
            "asn": 65101,
            "routerId": "10.200.255.11",
            "reachable": true
        },
        {
            "name": "leaf2",
            "url": "http://10.200.200.12:8080",
            "asn": 65102,
            "routerId": "10.200.255.12",
            "reachable": true
        }
    ],
    "nodes": [
        {
            "id": "edge",
            "kind": "router",
            "label": "edge\nAS 65000",
            "asn": 65000
        },
        {
            "id": "leaf1",
            "kind": "router",
            "label": "leaf1\nAS 65101",
            "asn": 65101
        },
        {
            "id": "leaf2",
            "kind": "router",
            "label": "leaf2\nAS 65102",
            "asn": 65102
        },
        {
            "id": "spine",
            "kind": "router",
            "label": "spine\nAS 65100",
            "asn": 65100
        },
        {
            "id": "172.19.0.2",
```

Recorded:

```text
routers=4/4 sessions=6/6 external=2
```

### 8. Open the dashboard

The page is at `http://127.0.0.1:8088/?router=spine`.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1200,700 \
  --user-data-dir=<tmp> --virtual-time-budget=4000 \
  --screenshot=demos/46-bgp-fabric/output/screenshots/dashboard-steady.png \
  http://127.0.0.1:8088/?router=spine
```

Recorded:

```text
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --disable-gpu --no-first-run --window-size=1200,700 --user-data-dir=<tmp> --virtual-time-budget=4000 --screenshot=/Users/olasumbo/gitRepos/cilium-implementation-poc/demos/46-bgp-fabric/output/screenshots/dashboard-steady.png http://127.0.0.1:8088/?router=spine
screenshot written after 2.0 s; chrome_rc=0
demos/46-bgp-fabric/output/screenshots/dashboard-steady.png: PNG image data, 1200 x 700, 8-bit/color RGB, non-interlaced
```

![Steady: fabric sessions 6/6 · server sessions 4/4; spine RIB holds
the loopbacks, wan and the VIP /32s.](output/screenshots/dashboard-steady.png)

### 9. Clear the spine's sessions and watch them come back

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

Recorded:

```text
event mark before clear: id=42
clear bgp * issued on spine
dashboard showed the drop after 1.49 s
screenshot written after 1.4 s; chrome_rc=0
demos/46-bgp-fabric/output/screenshots/dashboard-clear-bgp.png: PNG image data, 1200 x 700, 8-bit/color RGB, non-interlaced
dashboard confirmed recovery after 0.67 s (polled after the screenshots)
screenshot written after 1.4 s; chrome_rc=0
demos/46-bgp-fabric/output/screenshots/dashboard-recovered.png: PNG image data, 1200 x 700, 8-bit/color RGB, non-interlaced
events after the clear: 50
spine recovery: first Idle 2026-09-20T19:29:23.904Z last Established 2026-09-20T19:29:25.906Z recovered=yes window=2.002 s
```

![Clear: header `fabric sessions 0/6 · server sessions 4/4`; three
fabric links red; spine RIB is only `10.200.255.2/32`; kube-vip
sessions on the leaves stay Established.](output/screenshots/dashboard-clear-bgp.png)

![Recovered: header `fabric sessions 6/6 · server sessions 4/4`;
fabric links green; spine RIB restored.](output/screenshots/dashboard-recovered.png)

### 10. Confirm the agents stay on the management LAN

FORWARD drops transit onto `10.200.200.0/24`. INPUT accepts the
agent's port on mgmt and `lo`, and drops it everywhere else. Row 16
probes all four management addresses.

```bash
demos/46-bgp-fabric/check.sh
```

Recorded:

```text
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
```

## Checks

```bash
demos/46-bgp-fabric/check.sh
```

`check.sh` at `2026-09-20T19:29:40Z`: 16 rows, 15 PASS, 1 WARN, 0 FAIL.

Recorded:

```text
### 2026-09-20T19:29:40Z
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
  WARN   TCP MD5 in effect on the leaves                                        leaf1:TCP_MD5SIG-refused=9 leaf2:TCP_MD5SIG-refused=9  §8 row 3 — no CONFIG_TCP_MD5SIG here: sessions run unsigned
  PASS   dashboard reachable, 4/4 routers polled                                routers=4/4 sessions=6/6 external=2                  D8 — /api/state from 127.0.0.1:8088
  PASS   dashboard sessions agree with vtysh                                    6/6 = 6/6                                            D17 — state Established matches fabric-bgp-summary
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
demo 46 check: 0 FAIL
```

## What is deliberately not here

- No auth on the dashboard (lab; bound to `127.0.0.1` and `mgmt`).
- No TLS.
- No Kubernetes deployment of the dashboard (R7 optional later).
- No MD5 in effect (the known WARN): this VM refuses `TCP_MD5SIG`.
- No Mac route applied. D18 prints two lines;
  [fabric-vm-route.sh](../../scripts/fabric-vm-route.sh) `--apply` is the
  VM only.
- Cilium BGP and MetalLB FRR-K8s — demos 47–49, 57.
- `compose.lan-cilium.yaml` is written; the Cilium clusters are paused.
- One fabric per Docker host: the `/29` link subnets overlap with any
  second copy. `fabric-up.sh` refuses to start when another compose
  project already owns `10.200.1.0/29`.

## Runs that did not go to plan

The first dashboard run (`2026-09-20T13:32Z`) polled the agents over
the data plane (loopbacks). `clear bgp *` on the spine made the
dashboard lose the routers: `router spine/leaf1/leaf2
reachable→unreachable` at `2026-09-20T13:32:16.722Z`, back
`unreachable→reachable` at `2026-09-20T13:32:19.724Z`; the only
session events were the edge's. Recorded:

```text
event mark before clear: id=47
clear bgp * issued on spine
events after the clear: 18
spine recovery: first Idle None last Established None recovered=no
dashboard: no spine to=Established event within 60 s
```

The fix is the `mgmt` LAN (D8): agents bind
`10.200.200.{1,2,11,12}:8080`, not the loopbacks.

The `2026-09-20T13:43:31Z` apply failed when Docker gave the `mgmt`
bridge the first host address (`.1`), which is the edge's:

```text
Error response from daemon: failed to set up container networking: Address already in use
```

The gateway is pinned to `10.200.200.254`.

The `;reboot` probe first read as `0`: busybox `wget -S` prints the
status line twice and the parser took `$2`. [`check.sh`](check.sh)
records the fix: match the three digits after the HTTP token
("measured 2026-09-20: `$2` was `server`").

FORWARD alone did not isolate the agents. A reviewer's probe from
`client0` read `http://10.200.200.1:8080/show/bgp-summary` (200, the
edge's whole table) — a packet to the router's own management IP is
delivered locally and never reaches FORWARD (measured 2026-09-20,
[`fabric/entrypoint.sh`](fabric/entrypoint.sh),
[`tests/fabric-agent-mgmt-input.sh`](../../tests/fabric-agent-mgmt-input.sh)).
The live gate FAILED on that fabric. The `2026-09-20T19:29:04Z` apply
closed it: INPUT accepts the agent port on mgmt and `lo` and drops it
everywhere else; check row 16 is `client0_rc=28,28,28,28`.

## Clean up

```bash
demos/46-bgp-fabric/cleanup.sh
```

cleanup.sh calls `scripts/fabric-down.sh`. The fabric's own networks
go; `kind` and `kind-eg` stay.
