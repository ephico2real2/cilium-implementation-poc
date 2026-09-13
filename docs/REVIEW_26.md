# Review — demo 26: policy from observed flows

Adversarial second-opinion pass, 2026-09-12/13, on a 14-claim brief for demo 26 at head `b5219a2`.
Cursor (Grok 4.6 high fast, ask mode, no shell, no network) traced from the files and the recorded
transcript. Codex (gpt-5.6-sol, xhigh) worked on a `git archive` copy; its sandbox refused the live
cluster (`dial tcp 127.0.0.1:57308: operation not permitted`) but it fetched Cilium's and cf2cnp's source
and ran crafted streams through the scripts. Every verdict was re-checked here before a decision — the
re-check commands and their output are transcript Parts 13 and 15 of the demo. Fixes landed in
`31195a1` (Cursor's) and the commit that adds this record (Codex's).

## Verdicts

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 `get-flow.sh cli` filter | CONFIRMED (+ V1) | REFUTED (exit 141) | **Accepted** — measured live 141; the filter drains stdin now; Codex's snippet (`--output jsonpb`, exit before draining) rejected |
| C2 Loki selector and `\| json` names | CONFIRMED | CONFIRMED | — |
| C3 endpoint match by pod IPv4 | REFUTED (ambiguous) | REFUTED (IPv6; `cep-name:` prefix) | **Accepted twice** — first a uniqueness guard, then `cep-name:<ns>/<pod>` measured on 1.20.1 and adopted; no IP matching left |
| C4 `ingress: [{}]` vs `[]` | CONFIRMED | CONFIRMED (cites `rule_validation.go`) | — |
| C5 cf2cnp JSON mode, cache, download | PLAUSIBLE | PLAUSIBLE | **Accepted on the fact** — cited from `server.go` now (10–15 min TTL); the 601-second contract test rejected, the contract is unit-tested in the fork |
| C6 one policy per flow, named after the workload | CONFIRMED | CONFIRMED | — |
| C7 default-deny drops name no policy | CONFIRMED | CONFIRMED (cites `correlation.go`) | — |
| C8 dashboard JSON | CONFIRMED | CONFIRMED | — |
| C9 the `policy` metric | CONFIRMED (+ `redirected`) | CONFIRMED (cites `handler.go`) | **Accepted** — `redirected` in the prose |
| C10 the ring window | REFUTED | REFUTED | **Accepted** — ~100 s per agent at 40 flows/s; Codex's "balanced aggregate 186 s" rejected (rings are per agent, there is no aggregate) |
| C11 no INGRESS without a destination policy | CONFIRMED | REFUTED | **Accepted** — the parser returns INGRESS from endpoint locality on trace events; Part 3 and Exercise 1 reworded as an observation of this capture |
| C12 GUIDE runs as written | REFUTED | REFUTED | **Accepted** — `mkdir -p .tmp` |
| C13 Hubble UI framing | CONFIRMED | CONFIRMED | **Accepted** — clickjacking sentence added |
| C14 numbers match the record | REFUTED | REFUTED | **Accepted** — the 94 attributed to its capture with the recorded counts beside it (Codex's "delete the number" rejected: the screenshot is evidence, labelled as such); ~150 → 40 per agent; ~1.5 KB → 1592/1607 |

## C3 — matching the endpoint

**Findings.** Cursor: the IPv4 match is ambiguous (four hostNetwork pods share the node IP) and the
"only `cni-attachment-id`" claim had never been dumped; it proposed preferring `k8s-pod-name`. Codex: an
IPv6-primary pod is never found by an `ipv4` comparison, and 1.20.1 resolves endpoints by the
`cep-name:<namespace>/<pod>` prefix (`pkg/endpoint/id/id.go`).

**Re-check.** Dumped every endpoint's `external-identifiers` on poc1-worker2's agent: pod endpoints carry
exactly `['cni-attachment-id']`, reserved ones none — Cursor's preferred key does not exist here. Then
`cilium-dbg endpoint get cep-name:cf2cnp-lab/shop-6d7d797759-4ddlt` → id 1955, and `…/nope` → 404.

**Decision.** Accepted on the fact from both, Codex's mechanism adopted, both snippets rejected as written:
`audit-mode.sh` resolves the endpoint by `cep-name:` and configures it by id; a hostNetwork pod has no
CiliumEndpoint and is refused by the 404, an IPv6 pod resolves the same way. Measured on the real pod and
a missing one (Part 15).

## C10 — "seconds at ~150 flows/s"

**Findings.** Both: 4095 is the per-agent ring; ~150 flows/s is the relay's sum over 7 nodes.

**Re-check.** `cilium-config` has no `hubble-event-buffer-capacity` key (chart default); `cilium-dbg status`
shows `4095/4095` and 40.21 / 40.49 / 10.56 flows/s on poc1-worker / worker2 / control-plane. 4095 / 40.5 = 101 s.

**Decision.** Accepted; the README row and the script's message say ~100 s at 40 flows/s. Codex's
"7×4095/154 = 186 s if balanced" paragraph rejected: each ring is independent, no query spans them as one.

## C11 — "with no policy, nobody reports INGRESS"

**Finding (Codex).** An invalid generalisation of one capture: `decodeTrafficDirection` in
`pkg/hubble/parser/threefour/parser.go` has an INGRESS path for trace events from endpoint locality, reply
state and SNAT, independent of policy.

**Re-check.** Fetched the file at v1.20.1: for a trace event with a known CT reason, `isSourceEP != isReply`
→ EGRESS, SNATed → EGRESS, otherwise **INGRESS**; the policy-verdict path uses `pvn.IsTrafficIngress()`.
Cursor had marked the same claim CONFIRMED-for-this-lab / PLAUSIBLE-as-a-rule.

**Decision.** Accepted. Part 3 is retitled "in this capture, nothing reported INGRESS", says why it is not an
invariant, and names what *is* reliable: the destination's policy-verdict event, which exists only once a
policy selects the endpoint. Exercise 1 reworded the same way. Codex's replacement text not taken verbatim.

## C14 — numbers not in the record

**Re-check.** `rg -P '(?<![0-9A-Za-z])94(?![0-9A-Za-z])'` over the transcript and evidence: nothing; the 94
is the dashboard's *Total Flows* stat in the screenshot. `~150` is the UI's 155.6/155.7 rounded, and the
wrong denominator anyway (C10). `~1.5 KB` rounds 1592/1607.

**Decision.** Accepted: the 94 is attributed to the capture with the recorded counts beside it (README and
gotcha #82); the other two rewritten from the record; the TTL cited from cf2cnp's source.

## Not asked, and what happened to it

- **Codex, the single most important finding: `generate.sh` treated HTTP errors as success.** Re-check:
  transcript Part 1 shows three `http=400` answers whose bodies (`Request body is empty…`) were written into
  the `.yaml` files while the script exited 0. Accepted: `curl --fail-with-body`, the answer written to a
  temp file and moved into place only on success, the error printed with its status; measured on an empty
  body (exit 22, the existing file untouched) and on a real flow (200). Codex's snippet simplified (one
  temp file, no trap dance), its fake-curl test not carried into the repo.
- **Codex: GUIDE Exercise 10 queried `match="l7"`, which Cilium never emits.** Re-check: the live label
  values are `l3-l4`, `l7/dns`, `l7/http`, `none`; the handler writes `l7/<subtype>`. Accepted:
  `match=~"l7/.+"` with the values named.
- **Cursor V1** (SIGPIPE) and **V3** (only the `cli` arm skipped replies): accepted, one `first_request`
  function serves all four arms, exit codes measured before and after.
- **Cursor V2** is C12.

## Outcome

Fourteen claims: nine confirmed by both, four refuted by both (C3, C10, C12, C14), one refuted by Codex alone
(C11) and one by Cursor's volunteered finding (C1). All accepted on the fact; four snippets rejected in
whole or in part (C1's, C3's ×2, C10's aggregate paragraph, C14's deletion, C5's 601-second test) and
replaced by measured versions. Two unasked findings from Codex accepted, the generate.sh one being the
most consequential defect of the review. Re-validated after the edits: every `get-flow.sh` arm against the
live relay, Loki, the observer log and the export file; `audit-mode.sh` on the real pod and a missing one;
`generate.sh` on an empty body and a real flow; the guide's manifest dry-run; `mdfmt` clean. The second pass
on the fixed head is below.

## What each reviewer got right and wrong

- Codex had no cluster but read the right sources: the `cep-name:` prefix, the parser's INGRESS path,
  the `l7/<subtype>` label — three findings no amount of transcript reading gives. Its most important
  finding (generate.sh) came from reading the transcript's `http=400` lines that I had recorded and not
  read back.
- Cursor, with only the files, found the SIGPIPE exit and the mesh-versus-agent rate error, and refuted
  the pod-IP match on the right ground with the wrong mechanism (a key that does not exist on 1.20.1);
  its CONFIRMED on C11 was the surface read of my own sentence.
- Both reviewers' 4095 arithmetic used different per-agent rates (45.00 from demo 24, 40.5 measured now);
  both land at ~100 s. The lesson is the one the empirical rule already states: a rate has a scope.

## Second pass — the fixed head `3d11809` and the cf2cnp fork `a329000`

Twelve claims: five on the applied fixes, seven on the fork (the upstream PR). Cursor again had no shell;
Codex's turn was cut off by its provider's content filter after C1 ("flagged for possible cybersecurity
risk" — the brief asks for header-injection and body-limit attacks, which is what tripped it), having
measured only that every `get-flow.sh` arm passed the crafted streams (0 after a large post-request
drain, 1 on replies only, malformed text skipped). Its column is therefore C1 only.

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 `first_request()` on every arm | PLAUSIBLE | CONFIRMED (streams run) | — |
| C2 `cep-name:` lookup | PLAUSIBLE | — | — (noted: the hostNetwork refusal is by 404, exercised only for a missing name; a hostNetwork pod in the lab namespace would be the direct test) |
| C3 `generate.sh` | REFUTED (missing dir, no trap) | — | **Accepted** — directory check, `trap` on exit, JSON=1 errors to stderr; measured (Part 13b) |
| C4 Part 3 / Exercise 1 wording | PLAUSIBLE | — | — |
| C5 the review record's "measured" claims | REFUTED (141 never recorded) | — | **Accepted** — Part 13b records the old script's 141 against the new script's 0 |
| C6 `baseURL()` precedence and host | REFUTED | — | **Accepted** — `Forwarded` first as documented; a forwarded host must be a bare host[:port]; eight new test cases |
| C7 parser accepts `{}` | REFUTED | — | **Accepted** — a zero flow is refused with the reason; measured live (`http=400`) |
| C8 merge semantics | PLAUSIBLE | — | — (its collapse cases do not collapse: different selectors never merge) |
| C9 single-flow YAML identical to upstream | PLAUSIBLE | — | **Measured**: three fixtures, same md5 against a build of `main` |
| C10 chart 0.5.0 vs 0.4.0 | PLAUSIBLE | — | **Measured**: the diff is the version label and the `args` block; `helm lint` clean; a value with quotes renders valid YAML |
| C11 the page's script | PLAUSIBLE | — | — (no backtick, `textContent` only) |
| C12 500 flows in one request | PLAUSIBLE (no body limit — a risk) | — | **Measured**: 20 policies, 140 rules, 45 KB, 0.09 s; **N3 accepted**: 8 MiB cap (413 measured) and server timeouts |

Not asked: **N1** (README Part 4 still described the IP lookup) — accepted, fixed; **N2** (two workloads
sharing `app.kubernetes.io/name` and differing by `component` still yield two objects named alike) —
true; first left as a stated limitation, then changed at the operator's instruction with the Kubernetes
naming rule as the ground (one name per kind per namespace): the name is a function of the whole
selector and the selector's labels are carried as metadata — fork release 0.5.0, demo 26 Parts 14e–14f.

**Outcome.** Four refuted, all accepted and measured; the fork's reviewed head `2eb0f6b` is pushed to the
PR and rolled out on poc1 (Part 14d: https `download_url`, `{}` refused, a forwarded host with a path
ignored). Codex's aborted pass is a process note for the memory: a brief that asks for injection
attacks trips the provider's filter; phrase such claims as robustness tests.
