# Contributing upstream — what cilium/cilium is, how it takes changes, and what this lab has ready for it

Written 2026-09-17 from Cilium's own contributing guide and repository, quoted where it matters, for an engineer who has
not contributed to an open-source project before. Each candidate change lives in its own file here with the whole story
— the problem, where the data comes from, how it was captured, the fix, the screenshots, the benefit — and the exact
upstream steps. Nothing is posted to the upstream project without the operator's word.

## 1. What "cilium/cilium" is

`cilium/cilium` is the GitHub repository (github.com/cilium/cilium) of the Cilium project — the CNI, the Hubble
observability layer, the Gateway API implementation, the Helm chart, the documentation, and the Grafana dashboards this
lab runs — under the `cilium` organisation, a CNCF graduated project. Everything the lab installs comes from there:
the Helm chart at `install/kubernetes/cilium/`, the Hubble dashboards the chart ships as ConfigMaps at
`install/kubernetes/cilium/files/hubble/dashboards/*.json` (rendered by
`install/kubernetes/cilium/templates/hubble/dashboards-configmap.yaml`, one ConfigMap per file, when
`hubble.metrics.dashboards.enabled` is on), the metrics reference at `Documentation/observability/metrics.rst`, and the
code that emits the metrics at `pkg/hubble/metrics/`. A change to a dashboard the lab sees is therefore a change to a
file in that repository, proposed as a pull request.

Other upstreams this lab has contributed to or forked: `onzack/hubble-observer` and `onzack/cf2cnp` (the operator's
forks carry the lab's changes; the pull requests are #16 and #3 there).

## 2. How cilium/cilium takes a change — the process, from their guide

From the [contributing guide](https://docs.cilium.io/en/stable/contributing/development/contributing_guide/), in
order:

1. **An issue first, for anything but the smallest fix.** A bug gets the *Bug report* template
   (`.github/ISSUE_TEMPLATE/bug_report.yaml`: version, what happened, how to reproduce, Cilium / kernel / Kubernetes
   versions, regression yes/no, a sysdump, logs); a feature gets *Feature request*. "Before starting significant work,
   create a … GitHub issue describing your plans." The issue number is what the fix's commit will name.
2. **Fork, then a branch.** Fork the repository to your account, clone it, add the upstream remote
   (`git remote add upstream https://github.com/cilium/cilium.git`), branch from `main`. The guide recommends disabling
   GitHub Actions on the fork to avoid CI noise.
3. **Commits carry a sign-off — the DCO.** Every commit must end with `Signed-off-by: Name <email>`; `git commit -s`
   adds it. Cilium follows the CNCF DCO "real names policy": the name must identify you. Commit message shape: a
   subject `area: What changed`, a blank line, the why, then trailers — `Fixes: #<issue>` (auto-closes the issue on
   merge) and the sign-off. Each commit must build and work on its own (bisectable).
4. **A pull request** with a description of the motivation and the choices; a `release-note` block in the body
   (` ```release-note` … ` ``` `) with one user-facing sentence, no jargon; labels `release-note/<bug|minor|misc>` and
   `kind/<bug|enhancement>` if you can set them, otherwise reviewers add them; draft first if unfinished. CODEOWNERS
   assigns reviewers automatically; CI runs on the reviewers' `/test`. Keep a PR under ~200 lines or split it.
5. **After review**, re-request review once feedback is addressed; a maintainer merges.

### 2a. Their Generative AI policy — it applies to every contribution this lab makes

Cilium keeps it in the community repository, [`cilium/community/AI-POLICY.md`](https://github.com/cilium/community/blob/main/AI-POLICY.md)
(sections: Guiding Principle, Acceptable Use, Unacceptable Use, Generative AI for Translation, Transparency &
Attribution, DCO and Licensing). What it requires, quoted:

- **Declare it.** "We generally expect contributors to declare when Generative AI was used to prepare a submission."
  For anything non-trivial — "new features, documentation, complex design proposals" — "describe how Generative AI was
  used and explain the human review process applied." Only "trivial use of Generative AI (such as spelling check or
  simple autocomplete)" needs no declaration. And: "suspected use of Generative AI tooling without transparency may lead
  to submissions being closed or rejected without discussion."
- **Stay in the loop.** The contributor must be "involved in the entire process", must "personally review and edit
  generated content" and "fully understand and review the content prior to submission"; "you are fully accountable for
  the correctness, security, and clarity of your contributions" whether or not AI was involved.
- **The DCO still means you.** "If you submit AI-assisted contributions … you are personally certifying that you have
  the right to contribute the content under the project's license", and "if you're unsure about the licensing of code
  you created using Generative AI tools, **don't submit it**."
- No trailer format is mandated (no `Assisted-by:`), the declaration goes in the PR description; the policy carries
  no version or date.

How this lab meets it — every change here was prepared with an AI assistant (Claude Code) as the orchestrator, with
Cursor's agent writing code from briefs, and that is declared, not hidden. The declaration paragraph for a PR from this
lab, to be adapted, not copied blindly:

> **Generative AI use.** This change was prepared with an AI coding assistant (Claude Code, with Cursor's agent
> generating code from written briefs). The human contributor directed the work, read every line of the diff, and
> re-ran the measurements it rests on: <the measurement, e.g. "500 req/s through a Gateway to a backend on another
> node — 499.9 req/s on the proposed queries, 0 on the current ones; the before/after screenshots are from that run">.
> The mechanism was verified against the source (<file@version>) and the documentation (<page>), not taken from the
> assistant's word. The commit is signed off by the human contributor under the DCO.

Two consequences for how this lab works: the **sign-off is the operator's** (the DCO certifies a person's right to
contribute; the assistant has none), and the review record beside each change (`docs/REVIEW_*.md`, the adversarial
pass with Codex and Cursor) is exactly the "human review process applied" the policy asks to see described — say so
in the PR.

What this means for a dashboard change: the JSON file under `install/kubernetes/cilium/files/hubble/dashboards/` is
edited (and its twin under `examples/kubernetes/addons/prometheus/files/grafana-dashboards/`), the commit says why with
the measurement, the PR carries a screenshot before and after, and the release note says what a user will see.

## 3. What this lab has ready

| Candidate | Kind | File | Status |
|---|---|---|---|
| Hubble's `destination_workload` empty for Gateway traffic to a remote backend | bug report, then a dashboard PR | [hubble-l7-dashboard.md](hubble-l7-dashboard.md) | measured, drafted, patch made and verified — awaiting the operator's word to post |
| *Hubble Metrics and Monitoring* without a `cluster` variable | dashboard PR | the same file, §7 | the lab's copy measured (259.6 = 212.2 + 47.4); the upstream patch is the same script over the chart's file |
| The observer flow table's cluster columns | PR on onzack/hubble-observer | ephico2real2/hubble-observer#1 | on the fork, measured; goes upstream beside #16 |

## 4. The rule this lab keeps

Every claim in a report or a PR is a measurement that anyone can repeat with the steps written beside it; a screenshot
shows the before and the after; the lab keeps its own working copy of every change so nothing here waits on upstream.
It is fine to replace the lab's copies with the upstream shape once it lands — the generators here take the chart's
file as input, so the lab's dashboards follow whatever the chart ships.
