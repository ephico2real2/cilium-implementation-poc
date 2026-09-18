# Review — the upstream PR "hubble: name the workload of a remote endpoint" ported to cilium/cilium `main` (2026-09-18)

Three reviewers, the same brief (`scratchpad/review_brief_upstream_pr.md`: eleven claims — the L7 parser's four cases
on main's ID guard, nil-vs-empty encoding, `Equal` and `Upsert`, the watcher and the informer transform, the status
writer, the schema bump and `make manifests`, the generated files, fail-before/pass-after for every new test, the PR
text sentence by sentence, what a maintainer sends back, and the overlap with #48563), read-only, each in its own
space: **OB1** (Anthropic Fable 5.1, `Agent` `model: fable`, 68 tool uses, 33 min — ran the tests in the Cilium
builder, the fail-before runs in an rsync copy, the CEP writer test against a throwaway etcd, `controller-gen` into a
temp dir and `cmp` against the committed CRD), **Codex** (gpt-5.6-sol, xhigh, `codex-companion.mjs task`, 30 min — no
Docker socket from its sandbox, so tests by inspection plus cross-compiles), **Grok** (Cursor `cursor-grok-4.6-high-fast`).
Every finding below was re-read against the source before acceptance; the ones that changed the branch were re-run.

The thing under review: fork branch `hubble/remote-workload-main`, two commits on `cccadb0e70`; before the review
`da64f22cef` + `06c8cb9929` (21 files, +535 −6), after it `2fb374ce3a` + `63650a0445` (22 files, +628 −6).

## Where the three agreed

| Claim | Verdict (OB1 / Codex / Grok) | Evidence, short |
|---|---|---|
| C1 the seven parser on main's guard | CONFIRMED ×3, all three: the fourth case (a replacement endpoint with another ID) is **untested** | `parser.go:236-238` returns before `:247 endpoint.Workloads = nil`; OB1 ran the four cases through `Decode` — main's parser gives `Workloads(nil)` for the replacement case, the branch keeps `[{Deployment shop}]` |
| C2 nil vs empty encode alike | CONFIRMED ×3 | `proto.MarshalOptions{Deterministic:true}` byte-equal, `protojson` has no `workloads` key (Codex: `1a026e732a03706f64…` both) |
| C3 `Equal` compares workloads, `Upsert` honours it | CONFIRMED (OB1, Grok); Codex REFUTED the *scenario* not the code | `ipcache.go:373-374 metaEqual`, `:422-425`, `:505-510`; OB1's Upsert test FAILS with the Workloads block stripped from `Equal`. Codex's point: `updateExistingK8sPodV1` never calls `SetPod`, so an owner-reference change *after* creation never reaches the CEP writer — true, and true of main's local path too (out of scope, below) |
| C4 transform, watcher, slim `DeepEqual` | CONFIRMED ×3 | `factory_functions.go:63`, `cilium_endpoint.go:214-220`, `types/zz_generated.deepequal.go:52-67` |
| C5 the writer, `omitempty` | CONFIRMED ×3 | `endpoint_status.go:100,108-121`; `types.go:115` `json:"workloads,omitempty"`; nil and empty both serialise to `{"encryption":{}}` |
| C6 the bump, the CRD yaml | CONFIRMED ×3 (Grok PLAUSIBLE: did not rerun) | exactly one line in `register.go`; OB1 `cmp` of `controller-gen` output vs the committed yaml → IDENTICAL; Codex in a `git archive` copy → 25/25 yaml, 0 mismatches |
| C7 generated files | CONFIRMED ×3 | `zz_generated.deepcopy.go:2554-2558` make+copy; `deepequal.go:2129-2143`, `:2150-2163` |
| C8 fail-before / pass-after | CONFIRMED with a **correction** (OB1); Grok REFUTED the claim's breadth; Codex PLAUSIBLE (no Docker) | `pkg/endpoint`'s status tests are gated on `INTEGRATION_TESTS` — my "`ok pkg/endpoint`" was three SKIPs. OB1 ran them against an etcd: PASS on the branch, FAIL reverted. My own fail-before run covered `common` and `seven` only |
| C11 the overlap with #48563 | **REFUTED ×3 — the L7 half is in #48563**, only the bump is not | `gh pr diff 48563`: `seven/parser.go` lines 849–890 set workloads from `meta.Workload` and clear on the local pod; commit `748fc29714`, 2026-09-08; `grep -c register.go` → 0. Our own comment there says "you have this covered" — the draft contradicted it |

## Findings, accepted and applied

| # | Finding | Applied where | Re-measured |
|---|---|---|---|
| F1 | the replacement-endpoint case untested | `TestDecodeL7WorkloadsReplacementEndpointKeepsIPCacheWorkload` (OB1's text) → commit `63650a0445` | PASS on the branch (builder); FAIL on main's parser measured by OB1 (`actual: []*flow.Workload(nil)`) |
| F2 | `metrics.rst:1209` said schema **1.33.13** — the v1.20 branch's number; on main a 1.34.4 cluster is "later" and still prunes | 1.34.5 with the pruning caveat → commit `2fb374ce3a` | `grep` on the wrapped phrase; Grok's "single most important finding" |
| F2b | the contributing guide (`contributing_guide.rst:191`) wants user-facing changes in the upgrade notes | an *Informational Notes* bullet in `Documentation/operations/upgrade-next.inc` (the file the last three notes went to) | read |
| F3 | the PR text and the draft's rationale said #48563 lacks the L7 parser | rewritten: #48563 has both parsers; it lacks the bump and a cross-node measurement; a "decision" section with the two routes | `grep -c` of the false sentences → 0 |
| F4 | the release note prescribed "run the operator before the agents" — no such documented order (`upgrade.rst:125-127` says only "same version"); Helm rolls them concurrently | release note states the behaviour instead (the operator rewrites the CRD; an endpoint written earlier reports no workload until its status changes or the agent restarts) | read |
| F5 | the declaration claimed "a second human pass" (`REVIEW_CILIUM_FIX.md` records OB1 and Codex only) and a diff read that is still pending; and the body itself is AI-written text — `AI-POLICY.md` *Unacceptable Use* forbids posting that | the paragraph is now a fact list for the operator; §2a of `docs/upstream/README.md` gains the clause and the corrected process; the earlier three posts named as having been on the wrong side of it | read |
| F6 | `Equal` tested, `Upsert` honouring it not | `TestUpsertWorkloadOnlyChangeReachesMetadata` (OB1's text) → commit `2fb374ce3a` | PASS (builder); FAIL with the Workloads block removed from `Equal` measured by OB1 |
| F8 | the "all ok" for `pkg/endpoint` rested on skips | the verification list says so and cites OB1's etcd run | — |
| F9 | `parser.go (+18 −4)` was the total, `+14 −4` is right; `sig/hubble-api` owns `api/v1/flow/` (untouched), the label is `area/hubble` and the reviews come from `sig-hubble` et al. | draft | `git show --numstat` |

## Findings rejected, with the reason

| Finding | From | Why not here |
|---|---|---|
| Retry after API pruning: after a successful patch remember the *persisted* status when its workloads differ, so a pruned field is resent once the CRD is rewritten (`endpointsynchronizer.go` `lastMdl = mdl`) — Codex's "single most important finding" | Codex (OB1 confirmed the mechanism under C9b) | Real, and **pre-existing for every CEP status field**: `serviceAccount` (`d7ac791188`, 2025-08-15) shipped with only the schema bump, no synchronizer change, no upgrade note. Changing the synchronizer's contract is a design question for the maintainers, not a rider on a Hubble PR (`review-fixes-stay-simple`; upstream's ~200-line PRs). The PR text raises it as a shared limitation and the upgrade note documents it |
| Refresh the endpoint's Pod on pod updates (`SetPod` in `updateExistingK8sPodV1`) so a pod adopted by a ReplicaSet after creation gets its workload | Codex | Pre-existing: main's *local* workload path reads the same `ep.GetPod()`, so it has the same gap today; adoption after creation is rare (pods are created with their owner). Out of scope; noted for a possible upstream issue |
| `GetWorkloadMetaFromPod` mutates the cached Pod's label map (`delete(workloadObjectMeta.Labels, "deploymentconfig")` on a shallow copy) — a second lookup flips `DeploymentConfig/shop` to `ReplicationController/shop-rc` | Codex (measured: its test fails before, passes with `maps.Clone`) | A genuine upstream bug in `pkg/k8s/utils/workload.go`, untouched by this PR and older than it (OpenShift `DeploymentConfig` only). Belongs in its own issue/PR — recorded as a candidate in `docs/upstream/README.md` |
| F7 a test pinning nil-vs-empty proto/JSON encoding | OB1 (volunteered) | It tests protobuf's semantics, not this change; C2 is confirmed by measurement here, and the helper's nil returns are covered by the `without workloads` subtest |
| Add a cilium-cli connectivity test as #48563 does | all three name it a nice-to-have | Not a written gate (`contributing_guide.rst:296-312`); if Route A is taken and sig-hubble asks, #48563's test is the model |

## The verdicts that matter for the operator

1. **The code is sound** — every mechanism claim confirmed by reading and by fail-before/pass-after runs, including
   the writer test nobody had actually executed before OB1 stood up an etcd for it. Two tests and two doc fixes were
   added from the review.
2. **The PR text was not ready** — it told the maintainers and the author of #48563 something false about their PR
   (the L7 half), named a schema version that is wrong on `main`, prescribed an upgrade order the docs do not have, and
   claimed a human review pass that had not happened. All corrected in the draft.
3. **The posting process was wrong** — `AI-POLICY.md` forbids communicating with substantially AI-written text; the
   draft is now a fact sheet and the operator writes the words. §2a says so, and says which earlier posts it applies to.
4. **The case for a separate PR is thinner than we thought** — the draft's §"The decision" lays out Route A (open it as a
   smaller alternative) and Route B (feed #48563), with a recommendation for B first.

Run logs: `scratchpad/gotest-main.log`, `scratchpad/review_{ob1,codex,grok}_upstream_pr.txt`. Tetragon, whose four
agents the first builder run OOM-killed (gotcha #118), sat at 9–12m / 116–128 MiB through the final builder run at the
1Gi limit — no restarts.
