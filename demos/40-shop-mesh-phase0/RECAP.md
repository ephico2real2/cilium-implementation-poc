# What demo 40 did — the walk-through

**The goal.** Enhancement 002 takes the shop platform from demo 35 and runs it as *one* application on *two*
clusters, so that a customer with one URL — `https://api.shop.poc.local` — keeps getting answers even when a whole
cluster dies. Demo 40 is phase 0: no shop yet, only the ground it will stand on. Think of it as building the front
doors and the street address before moving the furniture in.

**1. One public address that can move between clusters.** A normal LoadBalancer address belongs to one cluster. We
wanted an address that *both* clusters know how to serve, but only one of them answers for at any moment — two
machines answering for the same address on one network is an ARP conflict, a coin toss on every packet. So a small
shared range, `172.18.255.16–.31`, was carved out of the block the network design reserves for shared addresses, and
the same pool definition (`cilium/lb-ippool-shared.yaml`) was put into both clusters. `.16` is the customer's address.

**2. The measurement that shaped the design.** Before writing anything, one thing was tested on poc1: can a single
Gateway (Cilium's front-door object — a Service plus listeners in the node's shared Envoy proxy) carry two addresses,
the shared one and the cluster's own? Yes: Cilium gave both IPs to the one Service. Then the second fact bit. The
object that *announces* addresses on the network, the L2 announcement policy, picks whole *Services*, not individual
IPs. If the shared address and the per-cluster address sat on one Service, poc2 would announce the shared one too, and
the conflict would be back. The fix is structural: **two Gateways per cluster** — `shop-gw` with the cluster's own
address (`.242` on poc1, `.177` on poc2) and `shop-vip-gw` with the shared `.16`. Announcing the shared address can
then be switched on and off without touching anything else.

**3. Exactly one announcer, proven.** Both clusters' existing announcement policies were told to ignore
`shop-vip-gw`. A separate, tiny policy — `shop-vip-announce` — is applied in *one* cluster, and that cluster answers for
`.16`. The review proved it on the wire: ARP requests for `.16` sent from a container on the same network segment got
three replies, all from poc1-control-plane's hardware address; and the TLS certificate handed back on `.16` carried
poc1's fingerprint, not poc2's.

**4. The switch, for disaster recovery.** `scripts/vip-takeover.sh poc2` moves the announcement: it first deletes the
policy from the other cluster, then applies it to the target — never two announcers, even for a second. Measured: the
lease (Cilium's record of which node answers for an address) moved to poc2 and back in about 40 ms each way; a lease
that has just been given up lingers about 15 s with an empty holder before it disappears. The review added the case the
script really exists for: if poc1 is *dead*, nothing can be deleted from it, so `--force` skips that step with a
warning, and `--status` reports "UNKNOWN" for a cluster whose API does not answer instead of pretending it is quiet.

**5. Certificates that work everywhere.** Both clusters already issue certificates from the same root
(`clustermesh-root-ca`, the same fingerprint on both — checked). Each cluster now has a `shop-tls` certificate for three
names: `api.shop.poc.local`, `api.poc1.shop.poc.local`, `api.poc2.shop.poc.local`. Not a wildcard, on purpose: a
`*.shop.poc.local` certificate covers one label, and the review measured that it rejects the two-label per-cluster names.

**6. The doors are open but the shop is empty — on purpose.** All four Gateways are programmed and answer on their
addresses with the right certificate, but with **404**, because no routes point at any backend yet. That is demo 41's
job. `check.sh` treats 404 as the pass mark for this phase and anything unreachable as a failure.

**7. Two programs, built now so they do not disturb later measurements.** `shopapi` is the small Go backend that
will talk to the database in phase 2: `/healthz`, `/ready` (a real `SELECT 1`), `/orders`, every answer stamped
`X-Served-By: <cluster>` so a client can see which cluster served it. It opens one connection pool with a one-second
connect timeout, runs as a non-root static binary, and is loaded onto all four nodes. `shopctl` exists twice, in Go and
in Python, with one behaviour: `probe` hits every path once; `load --rate N --duration M` sends steady traffic and
prints, per second, how many requests succeeded, how many failed and which cluster answered. It knows only the URL —
that is the customer's view of the mesh. The builds happen in this phase because gotcha #118 showed that heavy builds on
the Docker VM distort measurements (and OOM-killed Tetragon); the measuring phases stay clean.

**What the review caught** (OB1, Codex and Grok, `docs/REVIEW_DEMO40.md`):

- The check script called an unreachable door a PASS: curl printed `000`, a fallback appended another `000`, and the
  test rejected only `000`.
- The takeover script had no path through when the other cluster's API is down — the very scenario it exists for.
- The backend opened a new database pool on every request and, against a server that accepts and never speaks, waited
  the full two seconds; now one pool, one second.
- The two clients disagreed on how to spell three seconds (`3` versus `3s`); both now accept either.
- Cleanup left the TLS secret behind; the shared-address Gateway matched two address pools at once; the root README's
  table was missing demo 17.

After the fixes: 21 of 21 checks pass on both clusters, and the lab's regression check is 14 of 14.

**What you can do with it right now.**

- `scripts/vip-takeover.sh --status` — who announces the shared address (expect poc1).
- `curl -k --resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/` — a 404 from a real door.
- `scripts/vip-takeover.sh poc2`, the same curl, then `scripts/vip-takeover.sh poc1` — the address moves and comes
  back; the curl keeps answering.
- `demos/40-shop-mesh-phase0/check.sh` — the 21 checks, with the rule each one applies.

**Where the next demo starts.** Demo 41 moves the furniture in: the platform deployed in both clusters as global
services that prefer their own cluster, routes attached to both doors, the Gateway stamping `X-Served-By`, and the
network policies generated from what the traffic actually did.
