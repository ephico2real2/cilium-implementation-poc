---
name: demo-guide
description: Write a demo's RECAP.md as a structured guide — the page shape used by the Kubernetes docs (tutorial page), GitHub Docs (article contents), Google's developer style guide (procedures) and Diátaxis (how-to) — fixed headings in a fixed order, one imperative action per step with its recorded result, the architecture up front, the reference at the back, nothing about the runs that failed. Covers the demo's three pages — RECAP.md (the guide), README.md (the record) and GUIDE.md (the exercises). Invoke for every Envoy Gateway lab demo (50 onward; supersedes demo-recap's narrative walk-through) and whenever the operator asks for "a proper guide".
---

# Demo guide — the structured page

The operator, 2026-09-19, on the narrative recap: *"this is all over the place… google how to structure git doc for
writing a proper guide… I only wanna see what worked and how did it."* This skill replaces `demo-recap`'s walk-through
for the Envoy Gateway lab (demos 50, 51, 54 and on — the operator, 2026-09-19: *"update the other docs in demo 54
first and the previous demos on envoy with kubevip and metallb"*). The Cilium demos' recaps (40, 41, 53) stay.

## Where the shape comes from

| Rule | Source |
|---|---|
| A page is one content type; a demo guide is a **tutorial**: Overview → Prerequisites → Objectives → Steps → Cleanup → What's next | Kubernetes docs, [page content types](https://kubernetes.io/docs/contribute/style/page-content-types/): *"For `steps`, use numbered lists. Keep the focus on the task itself. If a step requires substantial background, link to the relevant concept page rather than repeating the explanation here."* |
| Title fully describes the page; every page has an intro; prerequisites sit **immediately before** the numbered steps; conceptual → reference → procedural → troubleshooting; a next-steps section when the page is one step of a larger process | GitHub Docs, [contents of an article](https://docs.github.com/en/contributing/style-guide-and-content-model/contents-of-a-github-docs-article) and the [content model](https://docs.github.com/en/contributing/writing-for-github-docs/content-model) |
| One primary action per numbered step, imperative verb first; *"State the action first and the result second. Keep the result in the same paragraph as the action"*; introduce a procedure with a sentence ending in a colon | Google developer documentation style guide, [procedures](https://developers.google.com/style/procedures) |
| Address the goal, not the tool; a logical sequence; *omit the unnecessary* — link to reference instead of embedding it; do not teach concepts in the middle of a procedure | [Diátaxis, how-to guides](https://diataxis.fr/how-to-guides/) |

## The file

`demos/<NN>-<slug>/RECAP.md`, linked from the demo's README in its first lines. The README stays the engineer's
full record (every command, every quoted output, the runs that went wrong); the guide is the page a reader follows.

## The template — these headings, this order, nothing else at H2

```markdown
# Demo NN — <what the reader will have at the end, in plain words>

<Intro: two to four sentences. What this demo builds, on what, and what it proves. No history.>

## What you get

- <one measured fact per bullet; four to seven bullets — the objectives, stated as results>

## Architecture

<ASCII diagram of the pieces and the path a request takes.>

| Name | Address | What it is | Who answers |
|---|---|---|---|

## Prerequisites

- <tool + version, from the pins>
- <the network route / hosts block / images — each with the one command that satisfies it>

## Steps

Introduce with one sentence ending in a colon, then one H3 per step:

### 1. <Imperative verb phrase>

<At most one sentence of why, with a link to the concept if it needs more.>

```bash
<the command as recorded>
```

Result: <the recorded output that proves the step, quoted or summarised in one line — numbers exact>.

### 2. …

## Verify

<The two to five commands a reader runs to see it working, each with its expected output. `check.sh` last, with
its recorded summary.>

## Reference

<Only what a reader will look up: the certificate spec (CN, SANs, issuer, secret), the issued leaf, the files
table, the address block. Tables over prose.>

## Troubleshooting

<Optional. At most three items: symptom → cause → fix, each one line, linking the gotcha.>

## Clean up

```bash
<the cleanup command(s)>
```

## What's next

- <up to five bullets>

```

## The rules

1. **Imperative, present tense, one action per step.** Step titles are verb phrases ("Install kube-vip",
   "Create the two doors"). A step that needs two commands is two steps or one command block with a
   result per command.
2. **Command, then result.** Every step shows the command as recorded and the result in the same block. The
   result is the recorded output (one to five lines) — an address, a status, a count — never a paraphrase of it.
3. **Every command is a fenced ```bash block — never inline in a sentence** (the operator, 2026-09-19: *"the
   commands that you use are not formatted with bash format and you add them to paragraphs"*). Inline backticks
   are for names only: a file, an object, an address, a flag. A sentence that contains `kubectl …`, `curl …`,
   `docker …`, `go run …`, `helm …`, `arping …` or a `scripts/*.sh` invocation is wrong — move the command into
   a block and keep the sentence about what it does. The same for *Verify*, *Prerequisites* and *Clean up*.
4. **Every number comes from `output/transcript.txt`, `docs/REVIEW_<demo>.md` or the plan.** Not remembered,
   not rounded.
5. **No history of the runs.** What failed on the way, what a reviewer caught, what was retried — none of it is
   in the guide. The README's record and `docs/REVIEW_*.md` hold that. The one exception is
   *Troubleshooting*: a symptom the reader may hit, with its gotcha link.
6. **Explain in one sentence or link out.** A mechanism gets one sentence at the step that uses it and a link
   (the plan, a gotcha, a source file with line numbers) for the rest. No paragraph of theory inside the steps.
7. **Terms get one gloss, once**, in parentheses, the first time: "kube-vip (a DaemonSet that answers ARP for
   the address)".
8. **No praise, no adjectives of quality.** Results carry the judgement.
9. **Length:** the prose outside code blocks and tables is 500–1,000 words. Longer means the README is being
   rewritten.
10. **Headings are fixed.** No H2 outside the template; *Troubleshooting* may be omitted; nothing else may.
11. **`scripts/mdfmt fix` after writing**, under bash, like every .md here; `tests/guide-structure.py <RECAP.md>`
    passes (heading order, one H3 per step, a command block and a "Result:" line in every step).

## The other two pages — same discipline

**README.md — the record.** For the engineer who runs and re-runs the demo. Fixed H2s, this order: intro (first
line *"For the reader in a hurry: [RECAP.md](RECAP.md) — the guide"*, then two to four sentences), **Files**
(table: file → what), **Run it** (the commands, each in a ```bash block, in order), **What was recorded** (one H3
per step, same titles as the guide's steps; under each: the command block and the recorded output in a ```text
block — quoted verbatim, the `readmeNN-verbatim.py` gate), **Checks** (the recorded `check.sh` block), **What is
deliberately not here** (bullets), **Runs that did not go to plan** (optional — the only place the history
lives: one short paragraph per run with its recorded line and the gotcha), **Clean up**. Prose between blocks is
one or two sentences; an explanation longer than that links to the plan, a gotcha or the review record.

**GUIDE.md — the exercises.** For the reader who has the demo up and wants to touch it. Fixed H2s: intro (one
sentence), **Prerequisites** (bullets; the hosts block as a ```bash block if a browser is involved), **Exercises**
(one H3 per exercise, `### N. <Imperative…>`; a sentence of purpose, the command block, an **Expect:** line with the
recorded output in a ```text block; three to five exercises, all read-only — anything that changes the cluster
says so in its title), **Clean up** (link to the README's).

Both obey rules 3–8 and 11 above. `tests/guide-structure.py --kind readme|guide <file>` checks the H2 order and
the no-inline-command rule; `--kind recap` (the default) checks the guide.

## The process

1. Read in full: the demo's README, `output/transcript.txt` (the last apply and the last check), `docs/REVIEW_<demo>.md`,
   the plan's row. Write nothing before all four are read.
2. List the steps as the reader will do them (the apply's sections are the skeleton), and for each the one
   command and the one recorded result.
3. Write the page from the template. Fill *Reference* from the live objects' recorded values.
4. Run `python3 tests/guide-structure.py demos/<NN>-<slug>/RECAP.md` and `bash scripts/mdfmt fix`.
