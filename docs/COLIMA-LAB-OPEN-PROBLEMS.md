# The Colima lab — the problem set, as it actually stands

**Scope: the new BGP labs only.** Colima hosts `46-bgp-fabric-colima` and the two BGP cluster labs that peer
with it. The existing labs stay on Docker Desktop, unchanged and unmigrated (the operator, 2026-09-20: *"we only
using colima for now for our BGP labs… don't migrate old labs"*). This document is the list of things that are unknown,
unproved or missing about the Colima side, written so somebody can work them one at a time instead of
discovering them mid-build. Plan: [enhancement 008](../enhancements/008-colima-lab.md). Each problem carries the
measurement that closed it, or the exact thing still owed.

## Where it stands, measured

| | Docker Desktop `:8088` | Colima `:8098` |
|---|---|---|
| routers | 4/4 (last read 2026-09-20T23:41:07Z) | 4/4 |
| fabric sessions | 6/6 | 6/6 |
| **server sessions** | **4/4** | **4/4** (2026-09-21T00:36:14Z) |
| external peers | `eg-poc1 (kube-vip) 172.19.0.2`, `.3` | `eg-poc1 (kube-vip) 172.20.0.3`, `.4` (`eg-poc1-colima-control-plane`, `-worker`) |
| TCP MD5 | not enforceable (linuxkit has no `CONFIG_TCP_MD5SIG`) | enforced on the fabric **and** on the kube-vip sessions — `md5` option on every segment both ways; a wrong key keeps the session down |

Docker Desktop was **quit at 2026-09-20T23:49:01Z** — its own backend log records `POST /app/quit … OK` from a
`docker-desktop-cli` client, then `sending desktop state:ExitHealthyState` and the socket closing. That is an
orderly `docker desktop quit`, not a crash (no diagnostic report), and it happened eleven minutes **before** the
Colima profile restart below (00:00:04Z). Nothing in this lab's scripts calls `docker desktop`; who ran it is not
visible from the lab. Until it is started again the `:8088` column above is history, and P5 cannot be run.

Inside the Colima VM now: the six fabric containers, `kind-registry` (`172.20.0.2`), and the two-node kind cluster
on `kind-eg-colima` — control-plane `172.20.0.3`, worker `172.20.0.4`. The Colima family has its own space
(P4): node LAN `172.20.0.0/16`, listen `172.20.0.0/17`, door `10.198.0.10`.

Kernel comparison (each kernel's own `/proc/config.gz`, 2026-09-20): `CONFIG_TCP_MD5SIG`, `CONFIG_NETKIT`,
`CONFIG_NET_SCH_FQ` and `CONFIG_TCP_CONG_BBR` are **absent on linuxkit 7.0.12** and present on Ubuntu 6.8.
Everything else the labs use (BPF, BTF, WireGuard, XFRM, VXLAN, GENEVE, macvlan, ipvlan, nftables, HTB) is on
both.

## P1 — the cluster does not peer with the fabric — CLOSED

**Closed 2026-09-21T00:03:28Z** (`demos/54-eg-poc1-kube-vip-colima`, transcript apply `2026-09-21T00:02:28Z`):

- `/api/state`: `routers 4/4 · fabric sessions 6/6 · server sessions 4/4 · external 2`, external nodes
  `172.19.0.3` and `172.19.0.4`, ASN 65021, hostnames `eg-poc1-colima-control-plane` / `-worker`.
- leaf1 `show ip bgp 10.98.0.10/32`: paths via `172.19.0.3` (best) and `172.19.0.4`, both `65021`, multipath;
  leaf2 the same two; the spine holds both leaves' copies.
- `client0 http://10.98.0.10/ → 200 curl_rc=0` — after the node return route `10.200.0.0/16 via 172.19.254.11`,
  which no Desktop script needed (Docker 29 in the VM isolates bridges; the reply left the node via its default
  gateway and died; `curl_rc=28` until the route).
- Screenshot `demos/54-eg-poc1-kube-vip-colima/output/screenshots/dashboard-cluster.png` (1200×700,
  `2026-09-21T00:02:36Z`): both nodes as dashed external peers, `server sessions 4/4`, leaf1's RIB with the door.

The "done when" said `server sessions 2/2`; two nodes × two leaves is **four** leaf-side sessions, which is what
the poller counts and what Desktop's `4/4` means too. `2/2` was an arithmetic slip; the row is `4/4` with
`external 2`.

## P2 — can kube-vip sign its session on this kernel? — CLOSED: yes; the kernel was the only blocker

**Measured 2026-09-20/21.** kube-vip `v1.2.4` vendors `github.com/osrg/gobgp/v4 v4.9.0` (its `go.mod`). In
`internal/pkg/netutils/sockopt_linux.go` the dialer's `DialerControl` calls `unix.SetsockoptTCPMD5Sig(…,
TCP_MD5SIG_EXT, …)` inside the `net.Dialer` `Control` callback and **returns the error** — a refused
`setsockopt` means no `connect()` is ever attempted, which is Desktop's "ACTIVE forever". On Ubuntu 6.8 the call
succeeds:

- DS env `bgp_peers=172.19.254.11:65101:lab-bgp:false,172.19.254.12:65102:lab-bgp:false`; both leaves keep
  `neighbor SERVERS password lab-bgp`. kube-vip logs `Peer Up` for both leaves ~2 s after start; no `sockopt`
  line.
- Wire (tcpdump in leaf1's netns, `eth2`): every segment on `172.19.0.x ↔ 172.19.254.11:179` carries
  `options [nop,nop,md5 …]` in **both** directions — the node's (gobgp's) and the leaf's (FRR's).
- Negative control, done on the **peer-group** key: `neighbor SERVERS password wrong-…` on leaf2 alone →
  both node sessions gone within 3 s and still absent at 31 s while leaf1 stayed 2/2; leaf2-netns
  `TcpExtTCPMD5Failure` 0 → 27; the wire shows the nodes' signed SYNs arriving with no SYN-ACK; key restored →
  both Established in 2 s. `check.sh` row 7 now does exactly this on leaf1 (`0/2 up in 10/10 samples,
  MD5Failure +14; restored in 9s`).
- The control that was there before proved nothing: `neighbor <node-ip> password …` on a listen-range peer is
  refused by FRR (`% Operation not allowed on a dynamic neighbor`, rc 1, nothing configured) and the `clear ip bgp`
  that followed it re-established the session in 6 s (dashboard events `23:45:47 Established→Idle`,
  `23:45:53 Idle→Established`). The MD5 counters must be read **in the leaf's netns**; the VM root namespace's
  are always 0 for a container's sessions.

Still owed from this problem's second half: the same experiment for MetalLB's FRR-K8s speaker (demo 52c, not
built yet). FRR-K8s is FRR, so it should sign the same way the fabric does — to be measured, not assumed.

## P3 — the Mac's path to a VIP inside Colima — CLOSED

**The premise was wrong.** `192.168.64.3` is the **`md5lab`** profile's address. The `bgp-fabric` profile had been
created without `--network-address` (`colima list` showed no `ADDRESS`; the VM had only Lima's user-mode
`192.168.5.3`), so the route line in the pages pointed at the wrong VM and no route could have reached this one.
Fixed 2026-09-21T00:00Z: `colima stop --profile bgp-fabric && colima start --profile bgp-fabric
--network-address --activate=false` (vz + Lima `vzNAT`, no `socket_vmnet`, no sudo on the Mac; the docker
context stayed `desktop-linux`; the fabric came back with `fabric-colima-up.sh`, the cluster's containers restarted
on their own). The VM now has `col0 192.168.64.4/24`; the Mac pings it (1.5 ms). `fabric-colima-up.sh` creates new
profiles with `--network-address` (enhancement 008 §3.1 rule 4) and prints the stop/start for an old one.

**Measured inside the VM**, with a throwaway netns standing in for the Mac (`10.250.0.2` via a veth into the root
namespace, cleaned up afterwards): the VM route for the VIP block via leaf1 alone → `curl_rc=28` — Docker
29.5.2's `FORWARD` policy is `DROP` and `DOCKER-FORWARD` accepts only what enters from a docker bridge; with
the `DOCKER-USER` accept toward the node-LAN bridge → `http_code=200`. `apply.sh` step 9 installs both
(idempotent, `-C || -I`); the return path needs nothing more — the node's reply leaves via the docker
gateway and is accepted as entering from the bridge.

**Closed 2026-09-21T00:36:14Z** on the re-addressed block. The operator's line (never run by a script;
printed by apply and check from `colima list --json`):

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

The old shared block should be deleted if it is still on the Mac: `sudo route -n delete -net 10.98.0.0/24`.
Apply `2026-09-21T00:35:36Z` recorded the route already in place (`10.198/24 → 192.168.64.4` on
`bridge100`) and `mac http://10.198.0.10/ → 200 curl_rc=0`. Check row 5 is PASS:
`route in place http_code=200`. The last hop is proved.

## P4 — the two runtimes overlap in address space — CLOSED

**Closed 2026-09-21.** The operator approved the re-addressing ("yes… it gives us a solid foundation")
before 52c copied the shared constants. The Colima family now has its own space; the Desktop labs
were not touched.

| What | Desktop (unchanged) | Colima family now |
|---|---|---|
| node LAN | `kind-eg` `172.19.0.0/16`, leaves `.254.11/.12`, listen `172.19.0.0/17` | `kind-eg-colima` `172.20.0.0/16`, leaves `172.20.254.11/.12`, listen `172.20.0.0/17` only |
| EG VIPs | `10.98.0.0/24` (poc1 `/26` at `.0`, poc2 at `.64`, anycast at `.192`) | `10.198.0.0/24`, same `/26` layout |
| Cilium VIPs | `10.99.0.0/24` | `10.199.0.0/24` (reserved; no Cilium on Colima; the Desktop `172.18.0.0/17` listen range was dropped) |
| fabric internals | `10.200.0.0/16` | unchanged — never routed from the Mac |
| the door | `10.98.0.10` | `10.198.0.10` |
| the Mac's VIP route | `10.98.0.0/24 → 192.168.64.2` | `10.198.0.0/24 → 192.168.64.4` |

Changed: leaf/edge/spine `frr.conf` listen ranges and prefix-lists, `compose.lan-eg.yaml`,
`fabric_colima_ensure_kind_net` (and the named subnet constants in `fabric-colima-lib.sh`),
the `/17` assert in `eg-colima-up.sh`, the kube-vip ConfigMap range, the door pin, the DS
`bgp_peers`, apply/check `DOCKER-USER`/route/`NET` constants, the Colima pages, and the
Colima-only tests. ASNs, mgmt `10.200.200.0/24`, ports 8098/5001 and every name stayed.

The Mac line is now `sudo route -n add -net 10.198.0.0/24 192.168.64.4`. The old
`10.98.0.0/24` route (if present) should be deleted — that prefix belongs to Desktop.

Unanticipated leftovers from the shared block: a `DOCKER-USER` accept for
`10.98.0.0/24` toward the previous node-LAN bridge (`br-39b96040a780`) can
survive a LAN recreate (the new bridge is `br-fde14ce0c6b3`). It is inert.
`check.sh`'s Mac-route grep is `^10\.198`, not `^10\.98` — the latter also
matches `10.198`. Dashboard testdata and the 46 claims/compose-config tests
had to allow the overlay (they previously forbade it).

## P5 — is the cross-VM question really closed?

We concluded the Desktop clusters cannot peer with the Colima fabric: overlapping subnets and Docker's
MASQUERADE mean the leaf sees `192.168.64.2` instead of the node's own address, so `bgp listen range
172.19.0.0/17` matches nothing and every speaker looks like one peer. That conclusion is sound but **was never
tested**, and the operator's instinct is that something is missing here.

Experiment, if it is worth the plumbing: a route in each VM for the other's block, plus a MASQUERADE exemption
(`iptables -t nat -I POSTROUTING -s <src block> -d <dst block> -j RETURN`) in each, then peer one Desktop node
with a Colima leaf and read the source address the leaf actually sees. Reverting is deleting two rules and two
routes. The value is knowing, not shipping. Two facts from P3 bear on it: the Colima VM now has a vzNAT address
(`192.168.64.4`) so the route half is possible, and Docker 29's `FORWARD` policy in the Colima VM would need a
`DOCKER-USER` accept for the Desktop node's block as well as the NAT exemption. Not runnable while Docker Desktop
is stopped.

## P6 — the things a reader needs that do not exist yet

- A single entry point: `scripts/colima-lab.sh up|down|status` (VM → registry → fabric → clusters), with each
  layer still runnable alone.
- Prerequisites that work on a machine **without Docker Desktop**: `brew install docker docker-compose
  docker-buildx colima kind` and the two `~/.docker/cli-plugins` symlinks, because the CLI and both plugins
  come from Desktop's app bundle today.
- Sizing guidance: `cpu`/`memory` can change after creation; `vmType`, `mountType` and shrinking the disk
  cannot. `network.address` **can** be turned on later (stop, start with `--network-address`) — measured.
- BBR is a module plus a sysctl on Colima (`modprobe tcp_bbr`, then
  `net.ipv4.tcp_congestion_control=bbr`) — `tcp_available_congestion_control` reads `reno cubic` until then.
- **Two Colima profiles fight over the Mac's ports.** Colima forwards each profile's published ports to the Mac
  with its own `ssh` forwarder; `md5lab`'s holds `127.0.0.1:5001` (its own `kind-registry`), so `bgp-fabric`'s
  registry on the same port is reachable only inside the VM — `curl 127.0.0.1:5001/v2/_catalog` on the Mac answers
  with `md5lab`'s catalog (`probe`). The scripts read the catalog in-container; a reader who curls the Mac's port
  sees the wrong registry. Either the family moves to a port nothing else publishes, or `md5lab` is stopped while
  the family runs. Measured 2026-09-20 (`lsof`: pid 93657 `colima-md5lab/ssh.sock` on 5001; pid 84360
  `colima-bgp-fabric/ssh.sock` on 8098 and the kube API port only).

## What must not happen while any of this is worked

The Desktop lab keeps running: the `bgp-fabric` project on `:8088`, `eg-poc1`, `eg-poc2`, and CRC. Every script
addresses a daemon explicitly (`docker --context …`), refuses `desktop-linux` by name, and restores the active
context in a trap — a stray `colima start` already took a port and killed the Desktop dashboard mid-run once
on 2026-09-20. The profile restart for P3 was checked against this: `docker context show` read `desktop-linux`
before and after, and the Colima ssh forwarder took `8098` and the kube API port only. Docker Desktop itself was
quit at 23:49:01Z by a `docker desktop quit` (its backend log, above) — before that restart and from outside this
lab's scripts; it has not been started again from here, because starting it is not in this lab's scope.
