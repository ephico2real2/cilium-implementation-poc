# Demo 46-colima — five things to try

Demo 46's password lines are unsigned on Docker Desktop. On this
Colima VM they are enforced. Five exercises against the fabric once
it is up. Exercises 1–3 only read. Exercise 4 runs the check (the
wrong-password row changes one session, then restores it). Exercise
5 clears the spine's sessions; they return on their own.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- docker context `colima-bgp-fabric` is running. Scripts refuse
  `desktop-linux`.

## Exercises

### 1. Print the status table

The status script is the four summaries plus a text topology with
the session states, then the dashboard one-liner.

```bash
bash scripts/fabric-colima-status.sh
```

**Expect:** every fabric neighbour Established (the recorded
tables).

```text
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.18     4      65100        17        17        5    0    0 00:00:32            3        5 spine
Total number of neighbors 1
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.2      4      65101        17        18        5    0    0 00:00:31            1        5 leaf1
10.200.1.10     4      65102        17        17        5    0    0 00:00:32            1        5 leaf2
10.200.1.19     4      65000        17        18        5    0    0 00:00:32            2        5 edge
Total number of neighbors 3
```

The same apply's dashboard line:

```text
routers=4/4 sessions=6/6 external=0
```

### 2. Traceroute from the outside world

From `client0` the path to leaf1's loopback is edge → spine → leaf1.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

**Expect:** the recorded hops.

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.006 ms  0.003 ms  0.001 ms
 2  10.200.1.18  0.001 ms  0.002 ms  0.002 ms
 3  10.200.255.11  0.001 ms  0.001 ms  0.005 ms
```

### 3. Count TCP-MD5 options on the wire

tcpdump in leaf1's netns. Zero packets with a TCP-MD5 option is a
FAIL. Kernel counters at zero are not enough.

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'echo "kernel=$(uname -r)"; grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

**Expect:** the recorded kernel line. Apply captured 20 packets,
each with `options [nop,nop,md5 …]`; check counted 18.

```text
kernel=6.8.0-117-generic
CONFIG_TCP_MD5SIG=y
```

```text
20 packets captured
20 packets received by filter
0 packets dropped by kernel
```

### 4. Run the check (wrong-password row changes one session)

The check keeps demo 46's rows and replaces the MD5 WARN with three
rows that FAIL when signing is not real. The mismatch row sets a
bad password on leaf1's session to `10.200.1.3`, waits until the
state leaves Established, restores `lab-bgp`, and waits until it
is Established again. A row that cannot restore is a FAIL.

```bash
bash demos/46-bgp-fabric-colima/check.sh
```

**Expect:** 16 PASS, 1 FAIL (dashboard sessions after the mismatch
flap). The three MD5 rows and the agent row:

```text
  PASS   sessions signed on the wire                                            md5-option packets=20                                §8 row 3 — TCP-MD5 option on the wire
  PASS   a wrong password breaks the session                                    Established→Idle; restored Established             §8 row 3 — mismatch tears the session down; restore required
  PASS   kernel has CONFIG_TCP_MD5SIG                                           CONFIG_TCP_MD5SIG=y kernel=6.8.0-117-generic         §8 row 3 — VM kernel CONFIG_TCP_MD5SIG=y
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
```

```text
demo 46-colima check: 1 FAIL
```

### 5. Clear the spine's sessions (changes state)

The sessions return on their own. The dashboard's event window is
the clock (`window=2.000 s`).

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

**Expect:** the recorded drop and recovery.

```text
dashboard showed the drop after 0.61 s
dashboard confirmed recovery after 0.67 s (polled after the screenshots)
spine recovery: first Idle 2026-09-21T00:33:02.023Z last Established 2026-09-21T00:33:04.023Z recovered=yes window=2.000 s
```

## Clean up

Same as the [README](README.md#clean-up).
