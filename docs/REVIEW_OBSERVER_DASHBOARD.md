# Review — the observer dashboard's panel research and redesign (branch `observer-dashboard-design`, 2026-09-17)

Codex (`codex exec -s workspace-write`, gpt-5.6-sol, xhigh) had the document, `dashboard-design.py`, the dashboard
before and after, and `flow.proto` at v1.20.2 — a shell, python and jq, no network. Cursor (`agent --mode ask`,
cursor-grok-4.6-high-fast) had the document alone. Every verdict re-checked before acceptance.

| Claim | Cursor | Codex | Outcome |
|---|---|---|---|
| C1 the `flow.proto` quotations are verbatim | Q1 CONFIRMED on the three semantics; doubted `POLICY_DENY` as a distinct enum value | REFUTED — two quotes altered: `DROPPED`'s comment shortened with `…` and `etc` dropped; the `denied_by` comment merged from two lines into one | both quotes restored verbatim; `POLICY_DENY = 181` **is** in the proto (`flow.proto:495`), so the split stands and the line now cites it |
| C2 the script — idempotent, 8 captions, no overlap, shifts, the query shapes, the overrides, no description overwritten, output identical to the deployed file | — | CONFIRMED on every point (`out == out2 == deployed`, deltas 8 rows everywhere below the Statistics row, nested panels moved too) | stands |
| C3 mechanism sentences vs measurements; "Now" cells vs the deployed captions | Q2 CONFIRMED on the visualization argument; "the name Grafana hashes is the field's" is an inference | REFUTED — the hashing sentence, the table/series explanation, the CommonMark and one-frame-per-series sentences are inferences; three "Now" cells quoted captions that the deployed file does not carry (they quoted the description or §5's test) | the inferences are now labelled as readings the fix confirmed, not code facts; the three cells quote the deployed captions verbatim |
| Readability (Cursor Q3) | three sentences named | — | the two-bug sentence split into two; `$logparser` defined where first used; the hashing sentence rewritten |

Also from Cursor: `traffic_direction` "says whose policy decided" holds for a policy drop only — the STALE drop's
direction is where the packet was seen; the row now says so and names `TRAFFIC_DIRECTION_UNKNOWN`. And `destination_names`
is filled when the source's DNS goes through the proxy — the `rules: dns` clause Cilium's DNS guide pairs with every
`toFQDNs` rule (`Documentation/security/dns.rst`, quoted).
