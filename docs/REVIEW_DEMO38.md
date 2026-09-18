# Review — demo 38, Grafana's visual grammar (branch `demo-38-grafana-visual-grammar`, 2026-09-17)

Codex (`codex exec -s workspace-write`, gpt-5.6-sol, xhigh) had the whole demo directory — README, `build.py`, the
scripts, the generated JSON, the screenshots — with a shell, python, jq and node, no cluster. Cursor (`agent --mode
ask`, cursor-grok-4.6-high-fast) had the README alone. Every verdict re-checked before acceptance; two were measured
on the lab before the text was changed.

| Claim | Cursor | Codex | Outcome |
|---|---|---|---|
| C1 `build.py` reproducible; layout, descriptions, captions, README ↔ JSON | — | REFUTED — byte-identical over three runs, no overlaps, 31 captions well-formed, every configuration claim present; but the *Raw* panel has no `description`, and the README's PromQL is abbreviated against the JSON | *Raw* has none **on purpose** (§4's point) — the README now says so; the README says once that its expressions are abbreviated and where the exact ones live |
| C2 the scripts | — | REFUTED literally — syntax clean, every `$variable` substituted, URL-encoded, `NO DATA` on zero, exit 0; but `capture.js` detects only `**` and backticks, not every raw-markdown form | the README now states exactly what the check detects (the marker bug's two symptoms) |
| C3 README accuracy vs JSON and screenshots | Q3 REFUTED — "six panels show the same query" (two are `rate()` of a counter), "two different numbers" (the screenshot shows both stats equal), by-name "one colour" vs "2 of 50 swatches", "≤ 6 slices" vs CPU by mode 8, 30 vs 31 vs 65 unreconciled | REFUTED — the same two sentences; the rest of the numbers correct; a list of unqualified Grafana-behaviour sentences | all rewritten: two lessons in §2 (the pod-count query; the `rate()` windows); the reducers "agree while nothing changes, part when a pod comes or goes (2.02 vs 2, captured)"; the bar gauge's 2 colours named as series + unfilled track; the CPU pie described as eight modes with four visible; 65 = 30 + 31 + 4 reconciled; a §0 sentence says what *measured* means here |
| Q1 technical accuracy (Cursor) | five sentences — `rate()` on a gauge count; "bars stop sorting — §2 says why"; "one CPU"; "by-name is not an option"; the `$__rate_interval` reason | — | all five accepted and rewritten: the sort sentence now says what was measured on this panel; "one CPU" → the node's CPU time, all cores; by-name "exists but mis-colours"; `$__rate_interval` explained by step vs window, not sample count |
| Q2 structure (Cursor) | §0/§4/§5/§6 lack a try-it; §2, §3, §5 carry two ideas | — | try-its added to §4, §5, §6; §2 split into "two lessons"; §3 and §5 keep their scope (colour modes belong together; growth is one idea with four tools) |

Measured while applying: a pie with *All values* on a range query shows one slice per sample named by the series
(`idle 4 %` × 25 over 15 minutes) — the README had said "timestamps"; corrected to the measurement.
