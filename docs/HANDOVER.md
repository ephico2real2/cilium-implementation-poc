# Handover — for the session that starts on the new MacBook

Written 2026-09-15 on the Intel MacBook, at `main` `01f1c3d`, for the first Claude Code session on the M5 Pro. Read
this, then `MEMORY.md` in the project's memory directory, then the tail of the latest session change log
(`docs/session-changelogs/2026-09-13_lab-in-ci.md`), then `enhancements/004-lab-in-ci.md` §4 *Where it stands* and
*Phase 4*. Everything below was measured on the day it was written; nothing here is recalled.

## 1. What this is

A Cilium + Hubble proof of concept on kind: two clusters (`poc1` 3 control planes + 2 workers, `poc2` 1 + 1) in a
ClusterMesh, 36 demos, 107 gotchas (`docs/GOTCHAS.md`), and — since 2026-09-13 — a GitHub Action that IS the lab:
`.github/workflows/lab-observability.yaml` builds both clusters, the stacks, the labs, generates policies from flows
with cf2cnp, re-tests under enforcement, runs every demo's check, and walks the pages with Playwright, with each
page's expectations as tests. The operator's direction: the Action stays the gate; a laptop bring-up is the same
scripts (`scripts/lab-*.sh`), and `docs/NEW-MAC.md` is the M5's path to them.

Public repository `ephico2real2/cilium-implementation-poc` (the directory carried the original name `cilium-kind-poc`
until 2026-09-15; the `/etc/hosts` block markers still do, on purpose — README says why).

## 2. The operator's standing rules (all measured against corrections given in-session)

- **Commits are the operator's**: `git -c user.name=ephico2real2 -c user.email=ephico2real@gmail.com commit …`,
  no `Co-Authored-By`, no "Generated with" footers — the global `CLAUDE.md` rule, which overrides any per-session
  attribution reminder. `main` takes direct pushes here (not in group-sync-dashboard, whose `main` is protected).
- **Measure before claiming, cite the source** — a run id, a file and line, a command's output. "Roughly" is not a
  number. The forensic second pass is a floor: re-read the premise, re-run the command, retract in words what the
  data refutes. Two of my own claims were corrected this way on 2026-09-15 (session log, the guide's section).
- **Every `.md` goes through `scripts/mdfmt fix`** after it is written; the repo's `.claude/settings.json` hook does
  it on Write/Edit and names what it cannot fix.
- **Gotchas** go in `docs/GOTCHAS.md`, numbered, and README's "N traps" count follows (107 today).
- **Adversarial review** before anything substantial ships: Codex
  (`codex exec --skip-git-repo-check --sandbox workspace-write -m gpt-5.6-sol -c model_reasoning_effort="xhigh"
  --output-last-message <file> … < /dev/null`) and Cursor (`agent -p --mode ask --output-format text --trust --model
  cursor-grok-4.6-high-fast "<brief>"` — the binary is `agent`; `cursor agent` needs the IDE's launcher). Each reviewer
  in its own scratch copy, never the tree; every verdict re-checked by me; the record in `docs/REVIEW_*.md`. The
  precise-artifact rule: file, lines, the claim, what to confirm or refute — never "review this".
- **The session change log** (`docs/session-changelogs/<start-date>_<slug>.md`, one per session, the approved format
  in group-sync-dashboard's `changelog` skill): appended after a commit is validated, never on push; who found what,
  what was decided, the measurement behind each line.
- **Outward-facing posts** (GitHub comments, PRs on other people's repositories) only on the operator's word — "Post",
  "Run", "use your judgement" were each given for a specific action, never in general.
- **Their machines are theirs**: on the Intel Mac, Docker Desktop stays quit unless the operator launches it and CRC is
  the operator's live cluster (never stopped by me). Expect the same courtesy on the M5: ask before the first
  `scripts/lab-up.sh`, and never touch CRC.
- **Skills to load before autonomous work**: `adversarial-review` (every PR), `changelog` (session start, after each
  validated commit, session end), `frontend-design` (page work) — they live in group-sync-dashboard's `.claude/skills/`.

## 3. Where it stands (2026-09-15)

| | |
|---|---|
| The Action | green end to end since run 34933611546; the latest, 34998586044 on `1e344ca`, carries the final dashboard layout and 2,456 observer lines in its artifact. Dispatch-only (`gh workflow run lab-observability.yaml`); inputs `audit_minutes` 3, `traffic_minutes` 6, `springboot` true, `obi`, `connectivity_test` |
| Upstream | onzack/hubble-observer: #9, #10, #11, #13 (via his #15), #14 merged, chart 2.7.0; **#16 open** (the two verdict panels, the named histogram, the layout, the doc), no maintainer comment yet. onzack/cf2cnp: **#3 open** (the fork's `develop`, 0.5.0 → 0.7.0, mergeable), five comments, all ours |
| The forks | `ephico2real2/hubble-observer` `develop` `37194a4` = upstream 2.7.0 + the cf2cnp 0.7.0 pin + the panels + `containerName` kept with its Container variable + the drill-down links + the CRI-aware `logparser` + the example; `ephico2real2/cf2cnp` `develop` = `feat/external-url-multi-flow` `cc99fcb` |
| Demo 36 | trust-manager's Bundle in every namespace of both clusters, the root in the runner's OS store and the Mac's keychain, Kyverno 1.19.1 mounting it into labelled pods — measured on the Action |
| The local loop | `demos/25-hubble-observer-loki/local-loop/` (Loki + Grafana in compose, the observer's lines replayed) — written, never run (Docker Desktop was quit) |
| The M5 | `docs/NEW-MAC.md`: tools, Podman Desktop and CRC beside Docker, Docker Desktop from the file (10 CPUs / 24 GB), then `scripts/lab-preflight.sh` — its netkit and host-route rows are the two things Apple silicon has never measured |

## 4. What is owed, in the order it should happen

1. **The M5 preflight**, before any cluster: `scripts/lab-preflight.sh`, read the table, and only then
   `LAB_TRUST_ROOT=1 scripts/lab-up.sh poc1 poc2` and the rest of NEW-MAC §4. Record the two unmeasured rows in
   `enhancements/004-lab-in-ci.md` phase 4 and as gotchas if they bite.
2. **Watch #16 and cf2cnp #3.** When #16 merges: open PR2 from a branch off upstream `main` carrying `develop`'s
   Container variable + `containerName` + the example + the links (`97cd4a8`, `37194a4`), then PR3 with the CRI
   `logparser`. When cf2cnp #3 merges and a chart is published, revert the fork's cf2cnp dependency pin to
   `oci://ghcr.io/onzack/helm-charts`.
3. **Bookkeeping owed**: 004 §2.1 rows for runs 34980519349, 34989024041, 34994075659, 34998586044; the operator's
   schedule question (004 §5 item 2); demo 34's hpv follow-ups.
4. **Phase 2b** — every demo describes itself (`demos/<nn>/lab.yaml` + a generic runner): designed in 004, not
   started.
5. The local loop's first run, once Docker Desktop is up on the M5.

## 5. The other projects on the same machine

They resume from their memory notes, not from this file: group-sync-dashboard (the note *c3-resume-point* — all
thirteen modules released, R1–R7 closed; CRC on the Intel Mac still runs it), openshift-rbac-automation,
group-sync-operator-helm-chart, the signal system. The private repository `ephico2real2/claude-config` carries the
global rules, the settings, the notes and `restore.sh`; its README lists what must be re-done by hand (logins, the
codegraph MCP server, the codex plugin, the npm tools, the vendored skills).

## 6. First commands on the M5, once NEW-MAC §1–§3 are done and `claude-config/restore.sh` has run

```bash
cd ~/gitRepos/cilium-implementation-poc && git log --oneline -3      # this file's commit or later
cat docs/HANDOVER.md; tail -60 docs/session-changelogs/2026-09-13_lab-in-ci.md
gh run list --workflow lab-observability.yaml --limit 3               # the gate's state
gh pr view 16 -R onzack/hubble-observer --json state,comments --jq '{state, n: (.comments|length)}'
gh pr view 3 -R onzack/cf2cnp --json state,comments --jq '{state, n: (.comments|length)}'
scripts/lab-preflight.sh                                              # the table; stop and report it
```
