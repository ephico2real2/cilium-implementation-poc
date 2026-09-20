# Demo 46 — the same fabric, with TCP MD5 actually enforced

Demo 46 carries one standing WARN: *"TCP MD5 in effect on the leaves —
no CONFIG_TCP_MD5SIG here: sessions run unsigned"*. Docker Desktop's
linuxkit kernel refuses `setsockopt(TCP_MD5SIG)`, so the password
lines are intent, not enforcement. On a Colima Ubuntu VM they are
enforced. This page brings up the same four FRR routers — edge, spine,
two leaves — and an outside-world client, inside project
`bgp-fabric-colima` on docker context `colima-bgp-fabric`. No kind
cluster is attached (one kind cluster per Docker context; that is the
next phase).

## What you get

- Apply `2026-09-20T23:09:15Z`. Four FRR routers in project
  `bgp-fabric-colima` running `frr-agent:colima` (built on
  `quay.io/frrouting/frr:10.7.1`): edge AS 65000, spine AS 65100,
  leaf1 AS 65101, leaf2 AS 65102.
- Six fabric eBGP sessions Established at the first poll;
  `converged after 0 s (1 polls)`.
- Loopbacks `10.200.255.1`, `.2`, `.11`, `.12` reachable from
  `client0` (`ttl=62`, 0% loss); traceroute `10.200.100.2 →
  10.200.1.18 → 10.200.255.11`.
- Kernel `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y`. Apply captured
  20 packets on leaf1, each carrying a TCP-MD5 option; check counted
  `md5-option packets=18`. Wrong password on leaf1→spine:
  `Established→Idle; restored Established`. While healthy,
  `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all 0. An unsigned
  session also shows zero failures — the proof is the wire count
  and the mismatch, together.
- Management LAN `10.200.200.0/24` (edge `10.200.200.1`, spine
  `10.200.200.2`, leaf1 `10.200.200.11`, leaf2 `10.200.200.12`,
  dashboard `10.200.200.100`, Docker bridge `10.200.200.254`); not
  in BGP.
- Dashboard `dashboard ready after 0 s (routers=4/4 sessions=6/6
  external=0)` on `127.0.0.1:8098`; `dashboard showed the drop after
  2.04 s`; `dashboard confirmed recovery after 0.67 s (polled after
  the screenshots)`; `spine recovery: first Idle
  2026-09-20T23:09:41.401Z last Established 2026-09-20T23:09:43.403Z
  recovered=yes window=2.002 s`.
- `check.sh` at `2026-09-20T23:09:58Z`: 17 rows, 17 PASS, 0 FAIL, 0
  WARN. Row 17: `client0_rc=28,28,28,28`.

Same fabric, two kernels:

| | Demo 46 (Docker Desktop linuxkit) | This run (Colima Ubuntu) |
|---|---|---|
| kernel | no `CONFIG_TCP_MD5SIG` | `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y` |
| MD5 check | one standing WARN: sessions run unsigned | three PASS: wire 18 packets, mismatch `Established→Idle` then restored, kernel `=y` |
| dashboard | `127.0.0.1:8088`, kind overlay | `127.0.0.1:8098`, `external=0` |
| compose | project `bgp-fabric` | project `bgp-fabric-colima` |

## Architecture

A packet from `client0` to a leaf loopback takes this path. The
`mgmt` LAN is out of band (not in BGP). No cluster is on this
context, so `external=0`:

```text
 MacBook
 browser 127.0.0.1:8098
        |
        v
 Colima VM (profile bgp-fabric, Ubuntu 6.8.0-117-generic)
 context colima-bgp-fabric
        |
        |                      company fabric (this demo)
        |   client0 10.200.100.10
        |      |  wan 10.200.100.0/24
        |      v
        |   edge  AS 65000   lo 10.200.255.1   mgmt .1
        |      |  10.200.1.16/29  (edge .19 · spine .18)
        |      v
        |   spine AS 65100   lo 10.200.255.2   mgmt .2
        |     / \  10.200.1.0/29            10.200.1.8/29
        |    /   \ (leaf1 .2 · spine .3)   (leaf2 .10 · spine .11)
        |   v     v
        | leaf1 AS 65101                leaf2 AS 65102
        | lo 10.200.255.11  mgmt .11    lo 10.200.255.12  mgmt .12
        | SERVERS listen 172.19.0.0/17 + 172.18.0.0/17 (no members)
        |
        |   mgmt 10.200.200.0/24 (not in BGP)
        |   dashboard .100  →  127.0.0.1:8098
        |   Docker bridge .254
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| client0 | `10.200.100.10` | outside world, default via `10.200.100.2` | netshoot v0.16 |
| edge | lo `10.200.255.1`, wan `10.200.100.2`, link `10.200.1.19` | border, originates `10.200.100.0/24` | FRR AS 65000 |
| spine | lo `10.200.255.2`, links `10.200.1.3` / `.11` / `.18` | transit, `multipath-relax`, `maximum-paths 8` | FRR AS 65100 |
| leaf1 | lo `10.200.255.11`, link `10.200.1.2` | ToR, SERVERS listen, `maximum-paths 8` | FRR AS 65101 |
| leaf2 | lo `10.200.255.12`, link `10.200.1.10` | ToR, SERVERS listen, `maximum-paths 8` | FRR AS 65102 |
| mgmt | `10.200.200.0/24` | out of band; not in BGP | Docker bridge `.254` |
| agents | edge `.1`, spine `.2`, leaf1 `.11`, leaf2 `.12` on `:8080` | allow-listed `show … json` | `frr-agent` |
| dashboard | `10.200.200.100`, published `127.0.0.1:8098` | live topology, Events, RIB | `bgp-dashboard:colima` |

Address plan:
[enhancement 006 §3.1 / §9.1](../../enhancements/006-bgp-tutorial.md).
Hand-off:
[NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md).

## Prerequisites

- Colima and a docker CLI that can name context `colima-bgp-fabric`.
  The up script creates profile `bgp-fabric` if `~/.colima/bgp-fabric`
  is absent (`vm-type vz`, `mount-type virtiofs`, 4 CPU, 6 GiB, 40
  GiB disk, DNS 8.8.8.8 and 8.8.4.4). `vmType` and `mountType` cannot
  change after creation; disk can only grow.
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  `FRR_IMAGE=quay.io/frrouting/frr:10.7.1`,
  `NETSHOOT_IMAGE=nicolaka/netshoot:v0.16`.
- One password: copy
  [`fabric/.env.example`](fabric/.env.example) to `.env` (default
  `lab-bgp`). Bind mounts must live under `$HOME` (the repo); Colima
  does not share `/var/folders`.
- Docker Desktop's `bgp-fabric` project, `eg-poc1`, `eg-poc2`, the
  `md5lab` profile and CRC stay untouched. Every script names
  `--context` and refuses `desktop-linux`.

```bash
test -f scripts/bootstrap/versions-eg.env
test -f demos/46-bgp-fabric-colima/fabric/.env.example
```

## Steps

Do these in order from the repo root:

### 1. Bring the fabric up

The up script starts the profile if needed, builds
`frr-agent:colima` and `bgp-dashboard:colima` in that context, and
waits for the six fabric sessions. It restores the previous docker
context on exit.

```bash
bash scripts/fabric-colima-up.sh
```

Result: `image frr-agent:colima present`;
`image bgp-dashboard:colima present`; six containers Healthy;
`converged after 0 s (1 polls)`; `dashboard ready after 0 s
(routers=4/4 sessions=6/6 external=0)`.

### 2. Watch it converge

Every fabric session is Established at the first poll
(`2026-09-20T23:09:18Z`).

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T edge vtysh -c 'show bgp summary'
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'show bgp summary'
```

Result: edge neighbor `10.200.1.18` AS 65100 `00:00:32` 3 prefixes;
spine neighbors `10.200.1.2` / `.10` / `.19` all Established,
`peerUptime` `00:00:31` / `00:00:32`.

### 3. Read the routes on spine and edge

The fabric-alone RIB is five prefixes: the WAN, the four loopbacks.
No VIP or cluster path.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T edge vtysh -c 'show ip bgp'
```

Result: `Displayed 5 routes and 5 total paths` on both.

### 4. Walk the path from the outside world

`client0` defaults via the edge. The path to leaf1's loopback is
edge → spine → leaf1.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Result: hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`;
`3 packets transmitted, 3 received, 0% packet loss, time 2034ms`;
`ttl=62`.

### 5. Read the servers' policy

The leaves listen for both lab `/17`s. No speaker has dialled; the
prefix-lists are already there for the next phase.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
```

Result: `2 IPv4 listen range(s)` — `172.19.0.0/17` and
`172.18.0.0/17`; no members; no `ttl-security`.

### 6. Prove TCP MD5 is on the wire

tcpdump in leaf1's netns must see the TCP-MD5 option. Zero packets
is a FAIL. Kernel counters at zero are not enough (an unsigned
session also shows zero).

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'echo "kernel=$(uname -r)"; grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

Result: `kernel=6.8.0-117-generic`; `CONFIG_TCP_MD5SIG=y`. Apply's
capture: `20 packets captured`, each
`options [nop,nop,md5 …]`. Counters while healthy:
`TcpExtTCPMD5NotFound 0`, `TcpExtTCPMD5Unexpected 0`,
`TcpExtTCPMD5Failure 0`. No `Unable to set TCP MD5 option` in the
recorded leaf logs.

### 7. Read the dashboard

The dashboard polls the four agents on `10.200.200.0/24` and
publishes on the Mac at port 8098.

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Result: `routers=4/4 sessions=6/6 external=0`. Screenshots:
`dashboard-steady.png` after 2.0 s.

### 8. Clear the spine's sessions and watch them come back

`clear bgp *` on the spine. The dashboard records the drop and the
return; the event window is the clock.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

Result: `event mark before clear: id=26`; `dashboard showed the drop
after 2.04 s`; `dashboard confirmed recovery after 0.67 s (polled
after the screenshots)`; `spine recovery: first Idle
2026-09-20T23:09:41.401Z last Established 2026-09-20T23:09:43.403Z
recovered=yes window=2.002 s`.

## Verify

The kernel line, then the check (the check's MD5 rows include the
mismatch, which changes one session and restores it):

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

```bash
bash demos/46-bgp-fabric-colima/check.sh
```

Result: `CONFIG_TCP_MD5SIG=y`; 17 rows, 17 PASS, 0 FAIL;
`sessions signed on the wire` `md5-option packets=18`;
`a wrong password breaks the session`
`Established→Idle; restored Established`;
`kernel has CONFIG_TCP_MD5SIG`
`CONFIG_TCP_MD5SIG=y kernel=6.8.0-117-generic`;
`demo 46-colima check: 0 FAIL`.

## Reference

| Item | Value |
|---|---|
| docker context | `colima-bgp-fabric` (scripts refuse any other name) |
| Colima profile | `bgp-fabric` — vz + virtiofs; disk can only grow |
| compose project | `bgp-fabric-colima` |
| images | `frr-agent:colima`, `bgp-dashboard:colima` |
| dashboard | `127.0.0.1:8098` (`FABRIC_COLIMA_DASHBOARD_PORT`) |
| password | `FABRIC_BGP_PASSWORD` in `fabric/.env` (default `lab-bgp`) |
| last apply | `2026-09-20T23:09:15Z` |
| last check | `2026-09-20T23:09:58Z` |
| files | [README.md](README.md), [GUIDE.md](GUIDE.md), [NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md) |

## Troubleshooting

- Symptom: script prints `refusing` and exits. Cause: `CTX` is not
  `colima-bgp-fabric` (or the context is missing / the VM is down).
  Fix: start the profile with the up script; do not switch the
  active context. The scripts restore the previous context on exit.
- Symptom: bind mount `not a directory`. Cause: Colima shares
  `$HOME` only; `/var/folders` is not mounted. Fix: keep config
  directories inside the repo.
- Symptom: `kind-eg` is unknown in this context. Cause: that network
  lives on Docker Desktop. Fix: this phase is the fabric alone;
  attaching a cluster is the next phase (one kind cluster per
  Docker context).

## Clean up

Stops the compose project. Leaves the Colima profile running.

```bash
bash scripts/fabric-colima-down.sh
```

## What's next

- Attach a kind cluster inside the Colima VM (one kind cluster per
  Docker context). Demo 46 on Desktop stays the overlay path to
  `kind-eg`.
- [GUIDE.md](GUIDE.md) — five exercises, including the wire count
  and the check's mismatch row.
- [NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md) — the hand-off;
  the MD5 row now cites the wire count and the mismatch.
