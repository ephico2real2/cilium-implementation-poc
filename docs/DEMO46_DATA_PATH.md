# Demo 46 — carrying a packet, not just a session

Demo 46 proves a great deal about BGP and nothing at all about traffic. Six
sessions come up, routes are learned, loopbacks answer — and every one of those
is the fabric talking about itself. The routers originate their own loopbacks
and their own WAN; no address in the lab belongs to anything outside it. A leaf
that listens and is never dialled has proved its configuration, not its
behaviour, and a VIP that is never reached has proved nothing at all.

This is the plan for the missing half: a service address announced by a server,
accepted by policy, carried across three autonomous systems, and **used**.

## What is already true

| | proved by | where |
|---|---|---|
| six fabric sessions Established | `check.sh` rows 1–2 | every run |
| every session signed with TCP MD5 | wire capture, kernel counters, a wrong-key control | `check.sh` rows 12–14 |
| loopbacks reachable from `client0` | `ping 10.200.255.{1,2,11,12}` | `check.sh` rows 3–6 |
| the leaves listen rather than name their peers | `bgp listen range` in the running config | `check.sh` row 9 |
| a server can dial in | kube-vip AS 65021, sessions Established | `servers-join.sh` |
| **a packet reaches a service address** | — | **nothing** |

That last row is what this plan closes.

## The address: allocated, not invented

`10.98.0.0/24` is the routed VIP block for the `kind-eg` fabric, carved per
cluster in [enhancement 006 §9](../enhancements/006-bgp-tutorial.md). The
allocation is not a convention — **it is enforced by the leaves' prefix-lists**,
and an address outside a named block is not "unusual", it is unreachable:

| block | prefix-list on the leaves | owner | allocated |
|---|---|---|---|
| `10.98.0.0/26` | `EG-POC1-VIPS` | eg-poc1, AS 65021 | `.10` `.11` demo 56's doors; **`.46` demo 46's probe** |
| `10.98.0.64/26` | `EG-POC2-VIPS` | eg-poc2, AS 65022 | `.74` `.75` demo 52's doors |
| `10.98.0.128/26` | **none** | reserved | — nothing here can be announced |
| `10.98.0.192/26` | `EG-ANYCAST-VIPS` | either cluster | an address both may announce |

The reserved `/26` looked like the tidy place for a test address until the
prefix-lists were read: there is no list naming it, so `SERVERS-IN` would
refuse it and the test would fail for a reason that has nothing to do with the
fabric's data plane. **`10.98.0.46/32`** therefore comes from eg-poc1's own
block — the cluster that announces it is eg-poc1, and AS 65021 is what
`as-path EG-POC1` permits — clear of demo 56's two doors, with the demo's
number as the last octet so nobody has to look it up twice.

Two fabrics, two blocks, the same reasoning:

| demo | engine | VIP block the leaves accept | this probe |
|---|---|---|---|
| [46](../demos/46-bgp-fabric-colima/) | Colima | `10.198.0.0/26` | `10.198.0.46` |
| [55](../demos/55-bgp-fabric-desktop/) | plain Docker | `10.98.0.0/26` | `10.98.0.46` |

`scripts/fabric-traffic.sh` defaults to demo 46's and takes demo 55's through
`FABRIC_VIP`.

## The path, hop by hop

Every hop is a policy decision, and each one is written down. Nothing here is
"it should route" — each arrow is a rule that has to match.

```text
  kube-vip on a node                 announces 10.98.0.46/32, AS 65021
  172.19.0.2 / 172.19.0.3
        │
        │  accepted only if BOTH match:
        │    prefix-list EG-POC1-VIPS   10.98.0.0/26 ge 32 le 32   (leaf1 frr.conf:39)
        │    as-path     EG-POC1        ^65021$                    (leaf1 frr.conf:31)
        │  route-map SERVERS-IN permit 10                          (leaf1 frr.conf:46-48)
        ▼
  leaf1 / leaf2   AS 65101 / 65102
        │
        │  route-map LEAF-OUT permit 20 → prefix-list EG-VIPS
        │    10.98.0.0/24 ge 32 le 32                              (leaf1 frr.conf:75)
        ▼
  spine           AS 65100      two nexthops, maximum-paths 8 → ECMP
        │
        │  route-map SPINE-OUT permit 20 → EG-VIPS                 (spine frr.conf:51)
        ▼
  edge            AS 65000
        │
        │  route-map FABRIC-IN permit 20 → EG-VIPS                 (edge frr.conf:34)
        ▼
  wan 10.200.100.0/24
        │
        │  client0's default route: `ip route replace default via
        │  10.200.100.2`                                     (compose.yaml:166)
        ▼
  client0 10.200.100.10            curl http://10.98.0.46/
```

Four autonomous systems, three eBGP hops, two of them ECMP. A packet from
`client0` to `10.98.0.46` crosses AS 65000 → 65100 → 65101 or 65102 → 65021.

## The return path: what is BGP's job and what is not

The leaves advertise **nothing** to their server peers:

```text
neighbor SERVERS route-map NOTHING out        (leaf1 frr.conf:24)
route-map NOTHING deny 10                     (leaf1 frr.conf:71)
```

That is deliberate, recorded in three places and gated by
`tests/fabric-servers-policy.sh:25`, and it is right. A Kubernetes
load-balancer speaker is **announce-only**: kube-vip and MetalLB exist to
advertise service addresses, and Cilium does not import BGP routes at all.
Sending a ToR's table to every node would be a leak, not a service.

But "the speaker needs no routes" is a statement about **announcing**. It says
nothing about how the node **replies**, and that is a separate question with a
separate answer: the node's own network configuration. In a real deployment
the node's default gateway is the ToR, so a reply goes back through the fabric
with no BGP involved. In this lab the node's default gateway is the Docker
bridge — and **Docker does not forward between two bridges**.

I got this wrong twice before measuring it. The record:

| claim | verdict |
|---|---|
| *"the leaves should advertise `COMPANY` with a `SERVERS-OUT`"* | **retracted** — the policy is correct as it stands; this is not BGP's job |
| *"the Docker host puts the reply back on the WAN bridge"* | **refuted** — CI's traceroute from `client0` reaches leaf1 at hop 3 and then `* * *` |

The measurement that settled it. On a laptop where the route IS installed, the
same request answers:

```text
client0 -> 10.198.0.10   http_code=200
eg-poc1-colima-worker:  10.200.0.0/16 via 172.20.254.11 dev eth0
```

So the lab installs the route the real topology would have provided, on each
node, exactly as
[demo 54c's apply.sh step 7b](../demos/54-eg-poc1-kube-vip-colima/apply.sh)
already does and for the reason its own comment gives — *"Docker's inter-bridge
isolation drops it"*. It is one `ip route replace` per node. It is not a change
to the fabric's policy, and the SERVERS contract is untouched.

What follows for this test:

- The **forward** path is proved by BGP across four autonomous systems.
- The **return** path is proved to exist, and is asserted separately, because
  its absence looks exactly like "the fabric does not work" from `client0` and
  is not.

## The password is a property of the kernel, not a constant

The leaves run `neighbor SERVERS password ${FABRIC_BGP_PASSWORD}`. Whether
that is *enforced* depends on the kernel underneath them:

| the leaf's kernel | FRR | an unsigned speaker | a signing speaker |
|---|---|---|---|
| no `CONFIG_TCP_MD5SIG` (Docker Desktop's linuxkit) | logs `Unable to set TCP MD5 option … Protocol not available`, continues unsigned | **works** | the leaf's kernel discards its segments |
| `CONFIG_TCP_MD5SIG=y` (Colima's Ubuntu, a CI runner) | signs | **never leaves ACTIVE** | works |

Demo 56's manifest carries `bgp_peers=…::false` — no password — and is right
for the VM it was measured on. Run 35942560154 put it on a runner whose kernel
takes the option, and it behaved exactly as
[NETWORK-TEAM-SHEET.md](../demos/46-bgp-fabric-colima/NETWORK-TEAM-SHEET.md) row 3
predicts — *"on a real kernel the speaker signs"*:

```text
kube-vip  SessionState:BGP_FSM_ACTIVE  DisconnectReason:IDLE_TIMER_EXPIRED
leaf1     Total number of neighbors 1        (the spine, and nothing else)
```

Nothing appeared in the leaves' logs, because on a signed socket the kernel
discards an unsigned segment before FRR ever sees it. A silent leaf is the
symptom, which is why `servers-join.sh` decides by reading the leaves' logs
for that refusal rather than by assuming either kernel.

## What has to be running

| piece | why | where it comes from |
|---|---|---|
| a kind cluster on the node LAN | somewhere for a node to be | `scripts/eg-up.sh eg-poc1` (demo 55) or `scripts/eg-colima-up.sh` (demo 46) |
| the fabric with the overlay | leaves on the node LAN | demo 46's or demo 55's `apply.sh` |
| kube-vip in BGP mode, AS 65021 | the announcement | `scripts/fabric-servers-join.sh` |
| a backend and a `LoadBalancer` Service | something to answer | `clusters/bgp-fabric-probe.yaml` |

The backend is deliberately the smallest thing that can answer an HTTP request
and name itself, so that a reply proves *which* pod served it. No Gateway, no
Envoy, no TLS, no application: those are demos 51–56, and every one of them
added here is a way for this test to fail for a reason that is not demo 46's.

## The assertions, in order

Each one is a separate claim and fails on its own. A `curl` that works while
the route is absent would mean the address was reachable some other way, which
is the failure this ordering is designed to catch.

1. **The leaves accepted it** — `10.98.0.46/32` is in leaf1's and leaf2's BGP
   table with as-path `65021`.
2. **Policy did the accepting** — `show route-map SERVERS-IN` shows sequence 10
   with a non-zero hit count.
3. **It crossed the fabric** — `10.98.0.46/32` is in the spine's table with
   **two** nexthops (`10.200.1.2` and `10.200.1.10`), and in the edge's.
4. **The kernel installed it** — `ip route show 10.98.0.46` on the spine shows
   an ECMP route, not just a BGP RIB entry.
5. **A packet arrives** — `curl -s http://10.98.0.46/` from `client0` returns
   the backend's own name.
6. **Repeatedly** — 20 requests, all answered; the count is reported, not
   assumed.
7. **The page says so** — `/api/state` reports the VIP among the routes, and
   the header's `server sessions` is non-zero.

## Four things this cost, and what each one teaches

Every one of these was found by running the lab somewhere it had never run.
None of them could have been found by reading the code, and none of them
showed up on the machine the lab was written on.

**1. A hardcoded neighbour address is an assumption about someone else's
cluster.** `leaf1 ping 172.19.0.3` passed for months because the recorded run
had a 1+1 cluster whose second node took `.3`. A single-node cluster puts its
only node on `.2` and the step fails. *Ask the network which nodes are there;
prefer the recorded address when it is present so a re-run reproduces the
record.*

**2. A stub is a contract, and it goes stale silently.** `fabric-up-converge.sh`
failed for months against a `curl` stub returning the four counters alone,
after `fabric-dashboard-state.py` started counting from the **records**. The
failure read as "needs a live lab", which kept it out of every sweep — a wrong
diagnosis is worse than none, because it stops anyone looking again. *When a
stub fails, ask what the real thing returns now.*

**3. A manifest that names a kernel property depends on that kernel.** demo
56's kube-vip sends no password, and its header says why: on the Docker
Desktop VM the kernel refuses `TCP_MD5SIG`, so a password would hold the
session in ACTIVE for ever. On a kernel that takes the option the opposite is
true, and the *unsigned* speaker never connects — with nothing in the leaf's
log, because the kernel discards the segments before FRR sees them. *Read the
comment that says "measured on this kernel" before moving the file to another
one; and decide such things by probing, not by constant.*

**4. A third-party action builds a different lab.** `helm/kind-action` gave a
green workflow that was quietly testing a single-node cluster while
`clusters/eg-poc1.yaml` is 1+1. The address mismatch surfaced it; a node
count, a taint, a CNI mode or the reserved-range assertion would not have.
*Build the lab with the repository's own scripts, or the run proves nothing
about the lab anyone uses.*

## What this still does not prove

- **That the return path is routed.** See above.
- **That ECMP balances.** Two nexthops in the table is not the same as traffic
  on both. Measuring that needs per-nexthop counters, which is demo 56's
  `ETP Local` work, not this.
- **That the VIP survives a node failure.** No node is stopped here.
- **Anything about TLS, HTTP semantics or an application.** A 200 with the
  right body is the whole contract.
