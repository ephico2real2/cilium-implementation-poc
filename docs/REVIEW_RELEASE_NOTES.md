# Review — the upstream-release-notes skill, its script, the first two reports, gotcha #117 and the 1.20.2 upgrade (branches `upstream-release-notes-skill` and `cilium-1.20.2`, 2026-09-17)

Two reviewers, each in its own scratch copy. Codex (`codex exec -s workspace-write`, gpt-5.6-sol, xhigh) had the
script, the skill, both reports, the script's raw outputs and the release body as fetched, gotcha #117, the moved pins
with the bootstrap's consistency check, `check.sh`, and the upgrade's evidence files (`helm get values` at revisions 5
and 7, demo 37's check before and after, the Gateway probe). Cursor (`agent --mode ask`, cursor-grok-4.6-high-fast) had
the two reports and #117, text only. Every verdict re-measured before acceptance.

## Verdicts

| Claim | Cursor | Codex | Outcome |
|---|---|---|---|
| C1 the script (Bash 3.2, `set -u`, tables, counts) | — | CONFIRMED — parsed by `/bin/bash` 3.2.57, independent counts 1/39/28/68/2 = 138 and 83 unmatched, nine tables with matching header/separator, the three `###` sections kept | stands |
| C2 the Cilium report's numbers and lab claims | Q1 arithmetic CONFIRMED; the outcome vocabulary REFUTED (three rows outside the skill's four) | REFUTED — 14 PR numbers all match their bullets and the bootstrap check passes with 1.20.2, but "every one a backport (each line names its `v1.20` backport PR and the `main` PR)" is false: 34 of 138 name one PR | both accepted (below) |
| C3 gotcha #117 and the Actions section against the evidence | Q2 CONFIRMED — `CoalesceValues(current.Chart, current.Config)` is the mechanism, `--reset-then-reuse-values` the remedy; one overstatement ("`--help` says as much in the negative") | REFUTED — values identical at rev 5/7 (`cmp` byte-equal), check before/after identical once pod names and lease holders are normalised, but "121 failed seconds … 2 min 12 s off the air" equates a 132 s span with a continuous outage | both accepted (below) |
| C4 the observer report and `check.sh` | Q3 CONFIRMED — the two-charts-one-version explanation is clear, the `Container`-variable argument sound; one sentence judges the maintainer | PLAUSIBLE — the raw output confirms 29/0, nine files, five merged and #16 open; the removals and what `*` resolves to came from `gh api`/`helm show chart` calls the raw output does not carry; `sed "s#^#    $gw: #"` breaks on a `#` in `$gw` (hypothetical: Kubernetes names cannot contain it) | the sentence rewritten as fact; `printf` replaces the `sed` |

## What was corrected

- **Report §title**: "every one a backport" → "104 of them name a `v1.20` backport PR and the `main` PR it carries, the
  other 34 (Renovate bumps, `[v1.20]`-only changes) name one PR" — Codex's count reproduced (`without_Backport_label=34`).
- **Report outcomes**: the skill prescribed four categories and the report used variants ("fixes something we run",
  "fixes a status we read", "enabled, unused"). The skill now names six — *fixes something we measured / fixes
  something we run / changes a written constraint / could hit us / neutral / not for us* — and every row opens with one
  in bold. The "In one paragraph" count is six rows with a lab side, two on measured mechanisms, not "five … measures".
- **#117**: "121 failed seconds … 2 min 12 s off the air" → "121 failed probes in the 132 s between +6 s and +138 s
  (eleven got through …) — a two-minute hole"; the `--help` sentence now says Helm's help does not warn under
  `--reuse-values` and that `--reset-then-reuse-values` describes itself.
- **Observer report**: "is likely all it needs" and "the argument the maintainer's message lacked" → the facts: what
  changed since #16 was opened, and that `a1b6f474`'s message gives the dashboard as its reason.
- **`check.sh`**: the per-listener line is printed with `printf '    %s: %s\n'` instead of a `sed` whose delimiter was `#`.

## What stands

The script's behaviour on all three projects; every PR number in the Cilium report; the pins and the bootstrap's
check; the identical user values across the upgrade; demo 37's check unchanged apart from pod names and lease
holders; the Helm mechanism (`pkg/action/upgrade.go` v4.3.0, `reuseValues`, read in the session and quoted in #117);
the observer report's numbers. Codex marked the transcript numbers (14 s, +29 s, +100 s, 35 s, the flow rates) and
the per-listener `Programmed=True` PLAUSIBLE because the evidence files did not carry them — they were measured in the
session and the report says where each came from; the per-listener line is now part of `check.sh`'s output so the next
run records it.
