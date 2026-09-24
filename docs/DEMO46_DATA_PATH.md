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

## The address, and where it comes from

Not invented. `10.98.0.0/24` is the routed VIP block for the `kind-eg` fabric,
carved per cluster in [enhancement 006 §9](../enhancements/006-bgp-tutorial.md):

| block | owner | already allocated |
|---|---|---|
| `10.98.0.0/26` | **eg-poc1** | `.10` `bgp-http-gw`, `.11` `bgp-grpc-gw` (demo 56) |
| `10.98.0.64/26` | eg-poc2 | `.74`, `.75` (demo 52) |
| `10.98.0.128/26` | reserved | — |
| `10.98.0.192/26` | anycast | an address more than one cluster may announce |

Demo 46 takes **`10.98.0.46`** from eg-poc1's `/26`. It is inside the block the
leaves will accept, outside the two doors demo 56 owns, and its last octet is
the demo's number so nobody has to look it up twice. One address, one `/32`,
one purpose: to be reached.

## The forward path, and the line that permits each hop

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

## The return path is not symmetric, and that is deliberate

The leaves advertise **nothing** to their server peers:

```text
neighbor SERVERS route-map NOTHING out        (leaf1 frr.conf:24)
```

So a cluster node learns no route to `10.200.100.0/24` from BGP. The reply to
`client0` leaves the node by its own default route — the `kind-eg` bridge,
owned by the Docker host — and the host puts it back onto the `wan` bridge,
which it also owns. Forward through the fabric, back through the host.

This is worth stating rather than discovering. It means:

- The test proves the **forward** path is a real routed path. It does not prove
  the reverse is.
- A reply that came back says nothing about how it came back. Any assertion
  about the return path must be made on the return path, not inferred from a
  successful `curl`.
- On a lab where the nodes *should* route back through the fabric, the leaves
  would need a `SERVERS-OUT` that advertises `COMPANY`. That is a change to the
  fabric's policy, not to this test, and it is not made here.

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
[NETWORK-TEAM-SHEET.md](../demos/46-bgp-fabric/NETWORK-TEAM-SHEET.md) row 3
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
| a kind cluster on `kind-eg` | somewhere for a node to be | `scripts/eg-up.sh eg-poc1` |
| the fabric with the overlay | leaves at `172.19.254.11/.12` | `demos/46-bgp-fabric/apply.sh` |
| kube-vip in BGP mode, AS 65021 | the announcement | `servers-join.sh` |
| a backend and a `LoadBalancer` Service at `10.98.0.46` | something to answer | this plan |

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

## What this still does not prove

- **That the return path is routed.** See above.
- **That ECMP balances.** Two nexthops in the table is not the same as traffic
  on both. Measuring that needs per-nexthop counters, which is demo 56's
  `ETP Local` work, not this.
- **That the VIP survives a node failure.** No node is stopped here.
- **Anything about TLS, HTTP semantics or an application.** A 200 with the
  right body is the whole contract.
