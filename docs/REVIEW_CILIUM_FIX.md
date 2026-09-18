# Review — the Cilium fix for cilium/cilium#25676 in the fork (branch `hubble/remote-workload-via-cep`, 2026-09-18)

Two reviewers on the fork's commits, each in its own space, the same brief (the data path end to end; the L7 parser;
the CRD and the operator; import hygiene and upstream fit), verdicts CONFIRMED / REFUTED / PLAUSIBLE with quoted
evidence. **OB1 — Anthropic Fable 5.1, a Claude Code Agent (`model: fable`)** — had the live fork read-only (55 tool
uses, 14 minutes; the second commit landed while it read, and it reviewed both). **Codex** (`codex exec -s
workspace-write`, gpt-5.6-sol, xhigh) had the diff, the touched files and the fork tree read-only. Grok was not asked:
the operator asked for "both with codex and ob1". Every finding below was re-measured or re-read before acceptance.

## The three commits

| Commit | What | Why |
|---|---|---|
| `9a4b6d39` | the workload on `CiliumEndpoint.status.workloads` (CRD 1.33.12 → 1.33.13), through the slim type and `factory_functions.go` into `ipcache.K8sMetadata.Workloads`, used by the **common** resolver's remote branch | the design |
| `cc2cf2e0` | the **L7 parser** (`pkg/hubble/parser/seven/parser.go`) takes `Workloads` from the ipcache metadata, the local pod overriding | the lab measured, one hour after the first image ran: L3/L4 flows named the remote workload, the Envoy-reported Gateway flow did not — the L7 parser resolves endpoints on its own and never called the common resolver. OB1 found the same line in the same hour ("commit 1 alone would have measured nothing on the L7 dashboard") |
| `1d3a02ab` | a local endpoint clears the metadata's workload before reading its pod (a bare pod reports none); the documentation names where the field stays empty | Codex C2: with the metadata consulted first, a local pod without an owner kept a stale value where it used to report nil |

## Verdicts

| Claim | OB1 | Codex | Outcome |
|---|---|---|---|
| Q1a every constructor of the slim CiliumEndpoint copies the field | CONFIRMED for the CEP path (live and tombstone arms); **CES** (`CoreCiliumEndpoint`) and **ClusterMesh/kvstore** (`IPIdentityPair` has no workload) do NOT carry it — and neither does the operator's own slim CEP | REFUTED the same two paths, with the lines | accepted as a **stated limitation**, not fixed here: the lab runs CES off and the measured flow is same-cluster; the documentation sentence names both (commit 3). Upstream's #48563 covers both |
| Q1b `K8sMetadata.Equal` includes Workloads; nil vs empty | CONFIRMED (len then element-wise; nil = empty, correct; a workload-only change upserts once) | CONFIRMED; order-sensitive, harmless while the producer emits ≤ 1 | stands; one more test case (nil vs empty) noted |
| Q1c the slice stored by value, backing array shared | PLAUSIBLE-safe (readers only; same aliasing as `NamedPorts`) | PLAUSIBLE | stands |
| Q1d `pkg/ipcache` importing the CRD package | REFUTED as a new dependency: `pkg/k8s/synced` already imported v2 | CONFIRMED direct dependency, no new transitive one; a maintainer may prefer a neutral DTO | kept for the demo; the DTO is on the upstream list |
| Q1e the writer's pod has owner references; the helper takes the slim pod | CONFIRMED (`GetWorkloadMetaFromPod(pod *slim_corev1.Pod)`, `OwnerReferences` kept, same pod the local branch uses) | — | stands |
| Q2 the CRD: what updates it, what happens if not | CONFIRMED the operator updates iff the label is LT 1.33.13; without the update the field is **pruned silently** (`replace /status`, no preserve-unknown-fields), "the demo would show nothing and log nothing" | CONFIRMED the same; the YAML is byte-identical to controller-gen's output | the deploy applied the YAML by hand **and** set the label to 1.33.13 on both clusters before rolling the agents; the CRD showed `workloads: array` before any measurement |
| Q3 tests | sound: each fails with its change reverted; four packages compile but cannot run on Darwin | the L7 "local overrides" subtest alone would pass with the seven change reverted (the "remote" one would not) | the L7 tests ran in a `linux/arm64` container: 3/3 pass including the new ownerless case; the common test likewise |
| Q3 commit message vs code | REFUTED for commit 1 alone ("the remote resolver sets Workloads … Envoy-reported flows are the common case" — the L7 parser never called it); with commit 2 the messages match; "Fixes: #25676" overstates (CES, ClusterMesh) | — | commit 2's message records the measurement; the "Fixes" line stays on the fork branch and would not go upstream as is |
| Q4 upstream fit | **cilium/cilium#48563** (open draft, 2026-09-08, 46 files) already does this with CES, the kvstore path, all three parsers, singular `workload`; its predecessor #36011 died in 2025 for being CEP-only; #48563 does **not** bump `CustomResourceDefinitionSchemaVersion` (a gap this branch got right) | the three gaps: CES, ClusterMesh (or scope it out), the local-ownerless clearing; plus release note, upgrade note, neutral DTO | **do not open a competing PR**: bring the schema-version bump and the measured Gateway reproduction to #48563 as review input — drafted under `docs/upstream/drafts/`, for the operator's review before anything is posted |

## What ran on the lab

Both clusters, the same image (`quay.io/cilium/cilium-dev:remote-workload` = `cilium-agent 1.20.2 1d3a02ab`, built on the
M5 in 39 s on warm caches, loaded into all four kind nodes), the CRD at 1.33.13 on both, both DaemonSets rolled in ~15 s,
`cilium status` OK, ClusterMesh OK. The measurement is in demo 39.
