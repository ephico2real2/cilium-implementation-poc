# Review record — the observer dashboard's two new panels and the bars under Statistics (upstream PR, 2026-09-15)

The change under review: the fork branch `feat/dashboard-drop-reason-and-denying-policy` of `ephico2real2/hubble-observer`
against `onzack/hubble-observer` `main` (chart 2.7.0): two pie panels under the Statistics row of the Cilium Flows
dashboard — *Flows per Drop Reason* and the policy that denied a flow — the untitled bar timeseries given a name,
a legend and an axis, and the doc section that had said the two fields were "not yet on the dashboard". The
operator's ask (2026-09-15): the bars "do not have any sort of label to understand what the data point means", then
"take it through a review". Reviewers on their own copies with an eight-claim brief: Cursor (Grok 4.6 high fast,
ask mode, no shell) and Codex (GPT-5.6, xhigh, a shell, Loki 3.7.7's parser and pipeline in a scratch module).
Every verdict re-checked here; the tests below were run on this machine.

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 layout after the inserts | REFUTED: the collapsed rows' nested children (ids 14, 3) kept their old `y`; Grafana's invariant is `child.y = row.y + row.h` | REFUTED on the same overlaps, "inactive: Grafana corrects them on expand" | **accepted** (Cursor's snippet): re-anchored to 38 and 39; harmless per Codex, correct per the invariant |
| C2 the JSON is upstream's plus the change | CONFIRMED (JSON-level diff: ids 15, 16 added; only id 11 changed; `gridPos` on 1, 4, 11, 12, 13) | REFUTED on the wording: the raw diff re-adds one unchanged line because the title changed the key order | held; the wording was too strict, the content is as claimed |
| C3 panel 15's query and `label_format` | CONFIRMED: `missingkey=zero` in `pkg/logql/log/fmt.go:379`, the template on panel 1 already uses `else if` | REFUTED: no `flow_verdict="DROPPED"` — with `verdictFilter: none` a FORWARDED flow becomes `DROP_REASON_UNKNOWN` (run through Loki's pipeline) | **accepted** (Codex): both panels filter on the verdict |
| C4 the L7 denial has no `drop_reason_desc` | CONFIRMED from the sources: `pkg/hubble/parser/seven/parser.go` 140–143 writes the zero reason and maps Envoy's denied verdict to DROPPED; `observer.pb.json.go` marshals without `EmitUnpopulated` | CONFIRMED, the same sources | held — the "Value" slice was the proxy's denials |
| C5 panel 16's JSON paths and the default-deny bucket | CONFIRMED, with a fact: a missing path yields an EMPTY label, not none (`parser.go` 712–718) — the template still branches right | REFUTED: every line without the arrays was "default deny" — FORWARDED, L7 and non-policy drops included; correlation can name a policy on an implicit deny too (`correlation_test.go` 696–721) | **accepted** (Codex): policy drops only (`POLICY_DENIED\|POLICY_DENY`), a name when given, "explicit deny (policy name unavailable)" for a nameless POLICY_DENY, "default deny (no matching allow)" for a nameless POLICY_DENIED; the title says "policy drops" |
| C6 the bars' title, legend, axis, `$__auto` | CONFIRMED (min interval floors `$__auto`; one legend row at h=6) | CONFIRMED | held |
| C7 the copied verdict colour overrides | CONFIRMED as leftover; one can fire (`ERROR_WRITING_TO_PACKET`) — "harmless, leave" | REFUTED: they fire on `INVALID_PACKET_DROPPED`, five `ERROR_*` reasons and any policy name carrying AUDIT/DROPPED/ERROR | **accepted** (Codex): removed from both new panels |
| C8 the doc section | REFUTED: "in every dropped flow's JSON" is wrong given C4 and C5; a replacement given | REFUTED, plus: "on every CI run" is more than one named capture supports | **accepted** (both): rewritten around the two empty cases; the capture named as one run's evidence |
| Not asked | nothing that breaks Grafana 11–13 or Loki 3.x; the LogQL shapes are already on panels 1 and 6 | the same | — |

## The tests

- `demos/25-hubble-observer-loki/logql-test/`: every panel's LogQL through Loki 3.7.7's parser, and the two policy
  panels' pipelines through Loki's engine on six synthetic flows (a FORWARDED flow, an L7 proxy denial, a default-deny
  drop, a named and a nameless `POLICY_DENY`, a `SERVICE_BACKEND_NOT_FOUND`). On the queries before the review:
  `panel 15: want "" matched=false, got "DROP_REASON_UNKNOWN" matched=true` for the FORWARDED flow, and every
  non-policy line in panel 16 as "default deny"; on the reviewed queries: `ok`.
- Cursor's layout test (the collapsed rows' invariant) and its doc test (no "every dropped flow", the two empty cases
  named): both pass on the branch.

## Outcome

Eight claims: three held by both (C4, C6, Not asked), one held on content and refuted on wording (C2), four
accepted refutations — Cursor's on the nested `y` and the doc, Codex's on the missing verdict filter, the policy
pie's scope and the copied colours. What generalises: a reviewer with the real engine (Codex ran Loki's pipeline
on synthetic lines) finds what reading the query cannot — the verdict filter that only matters when the stream
carries every verdict; a reviewer without a shell (Cursor) read the two Cilium sources that settle *why* the
"Value" slice existed. The branch at `d363425` carries all of it; the fork's `develop` (what the lab installs) at
`0594ec5`. Upstream PR: to be opened on the operator's word.
