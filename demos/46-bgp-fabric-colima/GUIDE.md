# Demo 46-colima — four things to try

Four read-only exercises against the fabric once it is up — the
recorded check is 17 rows, 0 FAIL (`md5-option packets=10/10 on 10.200.1.3`,
`Established→Idle, down in 15/15 samples; restored Established`,
`client0_rc=28,28,28,28`) and apply recorded the spine clear
(`dashboard showed the drop after 0.99 s`, `window=1.999 s`).

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
10.200.1.18     4      65100       299       290       29    0    0 00:05:08            6        5 spine
Total number of neighbors 1
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.200.1.2      4      65101       295       295       38    0    0 00:03:57            4        8 leaf1
10.200.1.10     4      65102       292       296       38    0    0 00:05:08            4        8 leaf2
10.200.1.19     4      65000       289       296       38    0    0 00:05:08            2        8 edge
Total number of neighbors 3
```

The same apply's dashboard line:

```text
routers=4/4 sessions=6/6 external=4
```

### 2. Traceroute from the outside world

From `client0` the path to leaf1's loopback is edge → spine →
leaf1.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

**Expect:** the recorded hops.

```text
traceroute to 10.200.255.11 (10.200.255.11), 30 hops max, 46 byte packets
 1  10.200.100.2  0.020 ms  0.003 ms  0.003 ms
 2  10.200.1.18  0.002 ms  0.002 ms  0.008 ms
 3  10.200.255.11  0.002 ms  0.002 ms  0.013 ms
```

### 3. Read the kernel MD5 flag

The VM kernel must carry the flag. The check's wire count and
wrong-key row are the proof that signing is real; the kernel
write-up is [KERNEL-EVIDENCE.md](KERNEL-EVIDENCE.md).

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'echo "kernel=$(uname -r)"; grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

**Expect:** the recorded kernel line and the check's three MD5
rows.

```text
kernel=6.8.0-117-generic
CONFIG_TCP_MD5SIG=y
```

```text
  PASS   sessions signed on the wire                                            md5-option packets=10/10 on 10.200.1.3               §8 row 3 — TCP-MD5 option on every leaf1–spine segment
  PASS   a wrong password breaks the session                                    Established→Idle, down in 15/15 samples; restored Established §8 row 3 — mismatch keeps the session down; restore required
  PASS   kernel has CONFIG_TCP_MD5SIG                                           CONFIG_TCP_MD5SIG=y kernel=6.8.0-117-generic         §8 row 3 — VM kernel CONFIG_TCP_MD5SIG=y
```

### 4. Read the dashboard

The dashboard polls the four agents on the management LAN.

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

**Expect:** the recorded one-liner.

```text
routers=4/4 sessions=6/6 external=4
```

## Clean up

Same as the [README](README.md#clean-up).
