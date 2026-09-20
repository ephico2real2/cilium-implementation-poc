# Demo 46-colima — the same fabric, with TCP MD5 actually enforced

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide.

Demo 46 carries one standing WARN: *"TCP MD5 in effect on the leaves —
no CONFIG_TCP_MD5SIG here: sessions run unsigned"*. Docker Desktop's
linuxkit kernel refuses `setsockopt(TCP_MD5SIG)`, so the password
lines are intent, not enforcement. On a Colima Ubuntu VM they are
enforced. Last apply `2026-09-20T23:09:15Z`; last check
`2026-09-20T23:09:58Z`: 17 rows, 17 PASS. The proof is the wire
count (`md5-option packets=18`) and the mismatch
(`Established→Idle; restored Established`), together.

Routers run `frr-agent:colima` built on
`quay.io/frrouting/frr:10.7.1`. Management LAN `10.200.200.0/24`
(edge `10.200.200.1`, spine `10.200.200.2`, leaf1 `10.200.200.11`,
leaf2 `10.200.200.12`, dashboard `10.200.200.100`, Docker bridge
`10.200.200.254`); not in BGP.

Same fabric, two kernels:

| | Demo 46 (Docker Desktop linuxkit) | This run (Colima Ubuntu) |
|---|---|---|
| kernel | no `CONFIG_TCP_MD5SIG` | `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y` |
| MD5 check | one standing WARN: sessions run unsigned | three PASS: wire 18 packets, mismatch `Established→Idle` then restored, kernel `=y` |
| dashboard | `127.0.0.1:8088`, kind overlay | `127.0.0.1:8098`, `external=0` |
| compose | project `bgp-fabric` | project `bgp-fabric-colima` |

## Files

| File | What |
|---|---|
| [scripts/fabric-colima-up.sh](../../scripts/fabric-colima-up.sh) | create/start profile `bgp-fabric`, build `:colima` images, compose up, wait for 6 sessions |
| [scripts/fabric-colima-down.sh](../../scripts/fabric-colima-down.sh) | compose down in `colima-bgp-fabric` only |
| [scripts/fabric-colima-status.sh](../../scripts/fabric-colima-status.sh) | four summaries, topology, dashboard one-liner |
| [scripts/fabric-colima-lib.sh](../../scripts/fabric-colima-lib.sh) | `CTX` gate, `dk`, restore-context trap |
| [fabric/compose.yaml](fabric/compose.yaml) | project `bgp-fabric-colima`, port 8098, images `:colima` |
| [fabric/.env.example](fabric/.env.example) | `FABRIC_BGP_PASSWORD` (copy to `.env`; gitignored) |
| [check.sh](check.sh) | 17 rows; MD5 wire / mismatch / kernel FAIL if unsigned |
| [apply.sh](apply.sh) | up + tables + MD5 evidence + screenshots + check |
| [cleanup.sh](cleanup.sh) | calls `fabric-colima-down.sh` |
| [NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md) | hand-off; MD5 row cites wire + mismatch |
| [GUIDE.md](GUIDE.md) | five exercises |

## Run it

From the repo root. The up script refuses `desktop-linux` and any
context that is not `colima-bgp-fabric`.

```bash
cp -n demos/46-bgp-fabric-colima/fabric/.env.example \
  demos/46-bgp-fabric-colima/fabric/.env
RECORD_STRICT=1 bash demos/46-bgp-fabric-colima/apply.sh
bash demos/46-bgp-fabric-colima/check.sh
```

Status only (fabric already up):

```bash
bash scripts/fabric-colima-status.sh
```

## What was recorded

Recorded from apply `2026-09-20T23:09:15Z`.

### 1. Bring the fabric up

```bash
bash scripts/fabric-colima-up.sh
```

Recorded:

```text
image frr-agent:colima present
image bgp-dashboard:colima present
 Container bgp-fabric-colima-dashboard-1 Healthy
converged after 0 s (1 polls)
dashboard ready after 0 s (routers=4/4 sessions=6/6 external=0)
```

```text
bgp-fabric-colima-dashboard-1   bgp-dashboard:colima      "/dashboard"             dashboard   36 seconds ago   Up 30 seconds (healthy)   127.0.0.1:8098->8080/tcp
bgp-fabric-colima-edge-1        frr-agent:colima          "/sbin/tini -- /usr/…"   edge        36 seconds ago   Up 36 seconds (healthy)
```

### 2. Watch it converge

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T edge vtysh -c 'show bgp summary'
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'show bgp summary'
```

Recorded:

```text
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.18     4      65100        17        17        5    0    0 00:00:32            3        5 spine
Total number of neighbors 1
```

```text
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.2      4      65101        17        18        5    0    0 00:00:31            1        5 leaf1
10.200.1.10     4      65102        17        17        5    0    0 00:00:32            1        5 leaf2
10.200.1.19     4      65000        17        18        5    0    0 00:00:32            2        5 edge
Total number of neighbors 3
```

### 3. Read the routes on spine and edge

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T edge vtysh -c 'show ip bgp'
```

Recorded:

```text
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.200.100.0/24  10.200.1.19              0             0 65000 i
 *>  10.200.255.1/32  10.200.1.19              0             0 65000 i
 *>  10.200.255.2/32  0.0.0.0                  0         32768 i
 *>  10.200.255.11/32 10.200.1.2               0             0 65101 i
 *>  10.200.255.12/32 10.200.1.10              0             0 65102 i
Displayed 5 routes and 5 total paths
```

```text
     Network          Next Hop            Metric LocPrf Weight Path
 *>  10.200.100.0/24  0.0.0.0                  0         32768 i
 *>  10.200.255.1/32  0.0.0.0                  0         32768 i
 *>  10.200.255.2/32  10.200.1.18              0             0 65100 i
 *>  10.200.255.11/32 10.200.1.18                            0 65100 65101 i
 *>  10.200.255.12/32 10.200.1.18                            0 65100 65102 i
Displayed 5 routes and 5 total paths
```

### 4. Walk the path from the outside world

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Recorded:

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.006 ms  0.003 ms  0.001 ms
 2  10.200.1.18  0.001 ms  0.002 ms  0.002 ms
 3  10.200.255.11  0.001 ms  0.001 ms  0.005 ms
```

```text
64 bytes from 10.200.255.11: icmp_seq=1 ttl=62 time=0.338 ms
64 bytes from 10.200.255.11: icmp_seq=2 ttl=62 time=0.082 ms
64 bytes from 10.200.255.11: icmp_seq=3 ttl=62 time=0.106 ms
3 packets transmitted, 3 received, 0% packet loss, time 2034ms
```

### 5. Read the servers' policy

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
```

Recorded:

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  Configured address-families: IPv4 Unicast;
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
```

### 6. Prove TCP MD5 is on the wire

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'echo "kernel=$(uname -r)"; grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

Recorded:

```text
kernel=6.8.0-117-generic
CONFIG_TCP_MD5SIG=y
```

```text
20 packets captured
20 packets received by filter
0 packets dropped by kernel
```

```text
    10.200.1.3.179 > 10.200.1.2.60986: Flags [.], cksum 0x17c3 (incorrect -> 0x0f8c), ack 20, win 501, options [nop,nop,md5 shared secret not supplied with -M, can't check - 00c23b6f6e09a0cdb5d6dc5a9dd57a53], length 0
```

```text
TcpExtTCPMD5NotFound            0                  0.0
TcpExtTCPMD5Unexpected          0                  0.0
TcpExtTCPMD5Failure             0                  0.0
```

### 7. Read the dashboard

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Recorded:

```text
routers=4/4 sessions=6/6 external=0
screenshot written after 2.0 s; chrome_rc=0
```

### 8. Clear the spine's sessions and watch them come back

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

Recorded:

```text
event mark before clear: id=26
clear bgp * issued on spine
dashboard showed the drop after 2.04 s
screenshot written after 1.4 s; chrome_rc=0
dashboard confirmed recovery after 0.67 s (polled after the screenshots)
spine recovery: first Idle 2026-09-20T23:09:41.401Z last Established 2026-09-20T23:09:43.403Z recovered=yes window=2.002 s
```

## Checks

Recorded `check.sh` at `2026-09-20T23:09:58Z`:

```text
== demo 46-colima — the BGP fabric (four FRR routers, Colima VM, TCP MD5 enforced)
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
  PASS   RFC 8212 in effect                                                     traditional profile, ebgp-requires-policy on         §8 row 5 — traditional defaults, explicit route-maps
  PASS   sessions signed on the wire                                            md5-option packets=18                                §8 row 3 — TCP-MD5 option on the wire
  PASS   a wrong password breaks the session                                    Established→Idle; restored Established             §8 row 3 — mismatch tears the session down; restore required
  PASS   kernel has CONFIG_TCP_MD5SIG                                           CONFIG_TCP_MD5SIG=y kernel=6.8.0-117-generic         §8 row 3 — VM kernel CONFIG_TCP_MD5SIG=y
  PASS   dashboard reachable, 4/4 routers polled                                routers=4/4 sessions=6/6 external=0                  D8 — /api/state from 127.0.0.1:8098
  PASS   dashboard sessions agree with vtysh                                    6/6 = 6/6                                            D17 — state Established matches fabric-bgp-summary
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only

demo 46-colima check: 0 FAIL
```

## What is deliberately not here

- A kind cluster. `kind-eg` exists on Docker Desktop, not in this
  VM. Attaching a cluster is the next phase (one kind cluster per
  Docker context). There is no `compose.lan-eg.yaml` in this
  directory.
- GTSM (`ttl-security`) on SERVERS. kube-vip and FRR-K8s send TTL 1
  and cannot pass it.
- The Desktop project `bgp-fabric` (port 8088), `eg-poc1`,
  `eg-poc2`, the `md5lab` Colima profile, or CRC. Scripts name
  `--context` and refuse `desktop-linux` before any daemon call.
- A secret in git. `fabric/.env` is gitignored; committed
  `frr.conf` has `${FABRIC_BGP_PASSWORD}`.

## Clean up

```bash
bash scripts/fabric-colima-down.sh
```

The Colima profile stays. The previous docker context is restored
on every script exit.
