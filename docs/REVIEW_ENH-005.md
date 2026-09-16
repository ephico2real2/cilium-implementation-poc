# Review — enhancement 005, the plan for demo 37 (two ways to deploy a Gateway)

Reviewed **before anything was built**, as the enhancements process requires. Two reviewers, nine claims, each in its own
scratch copy holding the plan, the shared Gateway's manifest, the LB pools and demo 09 Part 2's notes: Codex
(`gpt-5.6-sol`, xhigh, read-only) and Cursor on **Grok 4.6** (`agent --mode ask`, the operator's choice — ZDR). Every
refutation was checked against the live lab before it was accepted; the checks are the phase 0 results in the plan's §2.

## Verdicts

| Claim | Codex | Grok | Checked on the lab | Accepted |
|---|---|---|---|---|
| C1 a Gateway = one Service, shared per-node Envoy, no CPU isolation | wording REFUTED, architecture CONFIRMED | same | `get ciliumenvoyconfig` in `gw-probe` → one CEC; `cilium-dbg envoy admin listeners` on both agents → the probe's listener on both nodes | yes — "and a `CiliumEnvoyConfig`"; no Cilium knob gives a per-Gateway proxy (both reviewers' tables agree); `externalTrafficPolicy: Local` is incompatible with L2 announcements |
| C2 the address from `gateway-pool` in any namespace | CONFIRMED | CONFIRMED + **`.242` is enhancement 002's** | the probe got `.250`; `002-shop-platform-clustermesh.md:61` pins `.242` | yes — demo 37 takes `.243` |
| C3 the certificate path | path CONFIRMED, procedure REFUTED (unordered) | same; guessed the copy's name `<ns>-<secret>` | the copy is **`cilium-sync-secret-<sha256>`** (matched by `tls.crt`), Grok's name shape refuted; the ordered checks run as listed | yes — phase 0 rewritten in order, TLS handshake included, hashed name a gotcha |
| C4 the negatives — row 3 | "attached" CONFIRMED, conclusion REFUTED: a **hostname hijack** on any client whose DNS sends `*.poc.local` to `.240` | same, and names `scripts/hosts-entries.sh` as the client that would | not run (nothing built); the reasoning is the Gateway API's own (hostnames are not reserved across Gateways) | yes — row 3 is now the hijack shown at `.240` and `.243`, then the control (`ValidatingAdmissionPolicy` on hostnames) |
| C5 the noisy-neighbour method | REFUTED as an isolation measurement: L2 leader split, shared node/upstream CPU, unlike sibling, probe origin | same, plus: in-cluster fortio knows no `*.poc.local` | **the split is real now**: `routes-gw`'s lease on `poc1-control-plane`, the probe's on `poc1-worker` | yes — controlled runs (baseline, same-door sibling, other door, direct-to-Service, listener-saturating), lease holders recorded, same/split-node runs, same-image backends, separate pods |
| C6 the isolating variant | CONFIRMED conditionally (hold everything equal, force the poc2 address) | REFUTED as specified: 002 is unbuilt and its Gateway is the shop's | 002's status row: a plan | yes — the variant is its own route-app + Gateway on poc2, probe on the serving cluster, no mesh hop |
| C7 `edit` owns the Gateway | REFUTED | REFUTED | `can-i create httproutes/gateways --as=<edit SA>` → **no / no**; no `aggregate-to-edit` role for the group | yes — a `Role` in phase 1; the claim becomes "the platform grants the team its Gateway" |
| C8 risks | REFUTED as written (leases, ETP Local, `arp -a` weak, 4 vCPU host) | same | leases per Service measured (four `cilium-l2announce-*`) | yes — §6 rewritten |
| C9 scope | REFUTED: "one application" was two instances; the JSON identifies the request not the door; per-Gateway CPU unmeasurable; TCP not free | same | — | yes — one image, one backend behind both doors via ReferenceGrant for the functional proof, two identical backends for load; `X-Door` response headers; gRPC/TCP out of scope; "configuration scope, not runtime blast radius" |

## What was not accepted

- Grok's synced-Secret name `<ns>-<secret>`: the lab shows `cilium-sync-secret-<sha256>`.
- Codex's "check `.242` is free immediately before applying": moot, `.243` chosen; the check stays in `check.sh` for `.243`.

## Outcome

The plan's architecture claim survived both reviewers; its procedures did not, in five places, and each fix makes the
demo measure something it would otherwise have asserted: which door answered (header + address + leaf), the hijack a
shared Gateway permits and its control, the lease holders behind any "isolation", the RBAC a team actually needs, and a
cross-cluster variant that is truly a second data plane. Phase 0 ran the same day (§2 of the plan); phase 1 is next.
