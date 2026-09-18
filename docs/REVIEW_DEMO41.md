# Review — demo 41, the shop platform on the mesh, phase 1 (2026-09-18)

Two model reviewers and the orchestrator on one brief (`scratchpad/review_brief_demo41.md`, eleven claims): **Codex**
(gpt-5.6-sol xhigh — its sandbox blocked kubectl and Docker, so its live claims rest on the committed transcript and its
code findings on the files; shim tests measured), **Grok** (Cursor `cursor-grok-4.6-high-fast`). **OB1 could not run:
the Fable usage limit (HTTP 429) ended its pass before the first claim** — its slot is owed and will be run when the
limit resets; C2, the claim that mattered most, was decided by the orchestrator from Cilium's source and the live
tables instead (below). Every accepted finding was re-read against the code before Cursor applied it from the
reviewer's own snippet; the behavioural ones were re-measured after.

The thing under review: branch `demo-41-shop-mesh-phase1`, one commit on `c34a63c` before the fixes (`2813e3b`).

## C2 — `affinity: local`, decided from the source (the orchestrator, OB1's slot)

Cursor's measurement: with `service.cilium.io/affinity: local`, `cilium-dbg service list` shows only the local catalog
backend, and the remote one appears the moment the annotation is removed. Both reviewers and the orchestrator read
`pkg/clustermesh/selectbackends.go` (v1.20.2 and `main`): `SelectBackends` counts healthy local and ClusterMesh-sourced
backends, then `useRemote = localActiveBackends == 0 && remoteBackends > 0`, and the yield loop skips
`be.Source == source.ClusterMesh` while `!useRemote`. So the remote backends are **not selected for the frontend** —
not in the BPF map, not in the datapath — while any local backend is Active; they take over the instant the last one
goes. Live on poc1: `cilium-dbg statedb backends | grep shop-core/catalog` → **two** backends, `10.10.0.46` (Source
`k8s`) and `10.20.0.135` (Source `clustermesh`, ClusterID 2, active); `cilium-dbg bpf lb list` for `10.11.58.134:80` →
**one** selected (`10.10.0.46`). Cursor's first wording ("1.20.2 hides remotes in service list") named a display
filter; the mechanism is selection. The WARN rows became PASS rows measuring both numbers.

## Verdicts

| Claim | Codex | Grok | What held / what did not |
|---|---|---|---|
| C1 platform manifest | REFUTED (ratings listed as a Service; caller sidecars unprobed) | CONFIRMED (7 Services) | seven Services carry both annotations; `ratings` is a caller-only Pod — the comment and the plan row now say so; the alpine callers stay unprobed (traffic generators, not services) |
| C2 affinity | REFUTED (mechanism wording) | REFUTED (same) | decided from the source, above |
| C3 routes, header, 301 | REFUTED (301 not measured; a bare `http://<ip>/` cannot match the route) | REFUTED (301 not measured) | live: `--resolve host:80` → 301 `Location: https://<host>:443/`; a bare IP → 404 (no Host match); redirect rows added with the hostname |
| C4 the header's meaning | CONFIRMED | CONFIRMED | "It names the door, not whether the backend behind api-gateway was local or remote" (README:22) |
| C5 policies | REFUTED (stranger drop never measured; `-ge 6`; demo 35's objects share names) | REFUTED (flows mixed across clusters via the mesh relay) | see A4–A6 |
| C6 apply-both.sh | REFUTED (re-run wipes the enforced policies) | REFUTED (same) | A3 |
| C7 probe.sh | REFUTED (accepts a stale hosts entry) | REFUTED | A8 |
| C8 check.sh | REFUTED (`count_remote` counts the next Services' backends: `local=12 remote=12` on its own transcript) | REFUTED (`-ge 6`) | A1, A4 |
| C9 regression + CI | REFUTED (API error → WARN; workflow paths lack demos/40,41) | CONFIRMED | A9 |
| C10 docs | REFUTED (final table `X-Served-By=-` in the transcript vs headers in the README) | REFUTED (same) | A10 |
| C11 resources | PLAUSIBLE (no access) | PLAUSIBLE | measured after: ~18.9 GiB, ~1.0 core — **+1.9 GiB** over the §8 baseline for the platform ×2 |

## Findings, accepted and applied

| # | Finding | Fix, measured |
|---|---|---|
| A1 | `count_remote` read `grep -A20` past catalog's service | statedb + `bpf lb list` measurement, PASS on `known=2 (clustermesh=1) selected=1 local` on both clusters; shim before `local=1 remote=2`, after correct |
| A2 | the mechanism wording | README and plan cite `selectbackends.go`; plain English: known and held in reserve, not in the path |
| A3 | `delete ciliumnetworkpolicy --all` on every run | `remove_legacy_policies` deletes demo 35's set only before phase 1's `backend` policy exists; shim: zero deletes on re-run; the live re-run preserved all policies |
| A4 | policy row accepted `-ge 6`, never read audit mode | exactly the seven names (managed-by cf2cnp) + `8/8 policy-enabled, PolicyAuditMode=Disabled` per cluster via `cilium-dbg endpoint get`; shim: six → FAIL |
| A5 | enforcement never measured | `verify_enforcement` recorded on both clusters: stranger → catalog `wget: download timed out` (rc=1), shopper through api-gateway OK, Hubble `DROPPED stranger→catalog`, `FORWARDED api-gateway→catalog` |
| A6 | the flow files were mixed across clusters (the mesh relay): poc1's held 136 poc2 flows | `flows-both.sh` uses `hubble observe --cluster <name>` and filters `node_name`; files filtered (poc1 78, poc2 140); poc2 regenerates identically; poc1's 78 lacked the Gateway path — completed from poc1 alone (43 `reserved:ingress → api-gateway` flows, 30 api-gateway → backend), 151 lines, **every applied ingress rule reproduced identically**. Two cf2cnp extras rejected: an egress rule (phase 1 is ingress-only) and a `default/unknown` egress policy with an empty `endpointSelector` for the `reserved:ingress` source — a cf2cnp defect, recorded for the fork |
| A7 | no 301 rows | three redirect rows with the Host header; `Location` prefix allows `:443` |
| A8 | probe.sh accepted any resolution | compares with the live VIP; stale entry → exit 2 with both addresses; Darwin shim |
| A9 | API error reported as "Gateway absent" WARN; workflow paths | NotFound → WARN, anything else → FAIL (connection-refused shim → fail row); `demos/40-…/**`, `demos/41-…/**` in the paths filter |
| A10 | the final table printed `X-Served-By=-` (HTTP/2 lower-case header, CR) | parse fixed; apply-both.sh re-run and re-recorded; README quotes verbatim; `check.sh` recorded (33 PASS) |
| A11 | `ratings` is a Pod, not a Service | comment + plan row split |
| A12 | resources unmeasured | `kubectl top nodes` 396+244+200+167m, 7431+5534+3351+3079 Mi; `docker stats` 18.894 GiB — +1.9 GiB, CPU ≈ 1 core |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| Probes on the alpine caller sidecars | Codex C1 | traffic generators with no listener; a probe would test nothing |
| Re-apply poc1's regenerated YAML | (Cursor's first regenerate) | the 78-line regenerate lacked the Gateway rule; applying it would have denied the door; the evidence was completed instead and the live set left as is |
| cf2cnp's egress rule and `default/unknown` policy | A6 | out of phase 1's ingress-only model; the empty-selector policy is a generator defect, not a lab intent |

After the fixes: `check.sh` **33 PASS, 0 FAIL, 0 WARN** on both clusters; the lab's regression check **15 PASS** (the
new shop row in it); the VIP stayed with poc1 throughout. Reports: `scratchpad/review_{codex,grok}_demo41.txt`,
`scratchpad/c2_affinity_finding.md`. **Owed: OB1's pass on this demo** — recorded here so it is not forgotten.
