# Review — regression testing in plain words (branch `lab-regression`, PR #39, 2026-09-18)

Three reviewers, the same brief (four questions: the script under Bash 3.2 / `set -u` / `pipefail` and every place a
verdict could lie; the workflow on a fresh runner; the capture spec against the walker; the guide against the two run
files and the connectivity output), each in its own space, verdicts CONFIRMED / REFUTED / PLAUSIBLE with quoted
evidence:

- **OB1 — Anthropic Fable 5.1, a Claude Code Agent (`model: fable`)**, the first review under the operator's rule of
  2026-09-18 that OB1 gets the same instructions as the others; it had the live repository read-only and the live lab
  (read-only `kubectl`, `curl`, `gh`) — 44 tool uses, 7 minutes.
- **Codex** (`codex exec -s workspace-write`, gpt-5.6-sol, xhigh) — copies of the files, a shell, no cluster.
- **Grok** (`cursor agent --mode ask`, cursor-grok-4.6-high-fast) — the files, no shell.

Every refutation below was re-measured before it was accepted (the commands are in the session; the key ones are
repeated in the Outcome column).

## Verdicts

| Claim | OB1 | Codex | Grok | Outcome |
|---|---|---|---|---|
| Q1a Bash 3.2 / `set -u` / `pipefail` | CONFIRMED clean (`/bin/bash -n` 0, every `${x}` assigned first) | CONFIRMED | PLAUSIBLE (edges named) | stands |
| Q1b a FAIL printed as PASS | REFUTED ×2: row 14's success regex misses the CLI's real line `✅ [cilium-test-1] All 87 tests …` (read from the binary: `[%s] All %d tests …`); row 12 counts `→ ERR` lines as panels | REFUTED: agent health passes on exit 0 alone; L2 empty-holder count loses a trailing line to `$(…)`; cf2cnp tag parser needs a slash | REFUTED: the same health finding; observer requires `ready=1` not `ready==desired`; the double `000` in row 10 | all accepted — the regex is `✅ .*All [0-9]+ tests`, `→ ERR` counts as failure, health reads `Cilium: OK` and `Envoy DaemonSet: OK`, the empty-holder count is done in jq, the tag is "after the last colon, digest stripped", `ready == desired`, the second `000` removed |
| Q1c the pin parsing | CONFIRMED works today, brittle; "read `versions.env`, the copy CI builds from" | REFUTED robust (unquoted form, a comment first, `${X:-${Y}}`) | same | accepted — `EXPECT_CILIUM` now comes from `CILIUM_VERSION` or `scripts/bootstrap/versions.env` (`KEY=value`, the file the bootstrap asserts against) |
| Q1d exit code = FAIL count | CONFIRMED (tested `(exit 3) \| cat \|\| echo fails=$?` → 3) | CONFIRMED (mocked 13 → 13) | CONFIRMED on the happy path | stands |
| Q1e / Q2 the CA and the names on a fresh runner | REFUTED: `ROOT_CA` points at the OS bundle but `LAB_TRUST_ROOT` is never set, so the lab's root is not in it; rows 7/8/10/11/12 curl `grafana.poc.local` bare with no `/etc/hosts` (the full workflow runs `lab-route.sh`); row 4 probes `probe-*` (only in `60-perf.yaml`) and `bank` (only via `lab-apps.sh bank`) — "the first CI run cannot go green" | PLAUSIBLE — the same prediction from the source | REFUTED — the same three | all accepted: `LAB_TRUST_ROOT: "1"` in the job env, `scripts/lab-route.sh kind-poc1` after lab-up and after the stack, `--resolve` from the Gateway's address in every curl of the script, row 4 probes only names that have an HTTPRoute and lists the rest as "not deployed here" |
| Q2 `lab-apps.sh` invocations, `fails` output, connectivity path, demo 37 needs | CONFIRMED all; `LAB_APPS_SKIP` is a no-op with explicit labs; 30-team-gateway's issuer, pool address, namespace label all present in the trimmed stack | CONFIRMED | REFUTED "header-supported" (the header it had was the wrong script's) | the no-op removed; the rest stands |
| Q3 the walker's keys; `expect: {text: [shop]}` on JSON; the four uids | CONFIRMED (lines quoted; the uids answered live with 21/38/12/7 panels); `tut-6`'s `noDataAllowed: []` a risk on 2 minutes of traffic | CONFIRMED (substring match, `shopper` passes) | CONFIRMED | stands; the risk noted for the first CI run |
| Q4 the guide vs the files | REFUTED: 8 distinct flagged lines (4/2/1/1), not 16 (8/4/2/2) — the report prints each twice; no health line at 22:34; the prose quotes run 1's numbers under run 2's table; "on every branch" (the full workflow is dispatch-only); "exactly as the CI runs it" (the full workflow adds sysdump flags); "two minutes" (62 s); "70 minutes in" unclear | REFUTED — the same counts and numbers | REFUTED — the same, plus three junior-unfriendly sentences | all accepted and rewritten; the pasted run is the run after the fixes (14 PASS) |

## What was not accepted, and why

- Grok: `check_cilium_version` requires a digest-pinned image — the chart pins by digest (`useDigest: true`), and a
  chart that stopped would be worth a FAIL; kept.
- Codex: "listener correctness is an aggregate equality" — `N listeners, N True` is the row's stated rule; kept.
- Codex/Grok: the Gateway address lookup falling back to DNS when the cluster gives no address — the fallback is the
  Mac's `/etc/hosts`, which is where the check ran before; kept, and the row prints which address it used only on
  failure.
- The walk's password `poc-grafana` is the chart value (`values-kube-prometheus-stack.yaml:53`) and the live secret;
  the script reads the secret — both true today; kept.

## Outcome

Fourteen rows again, 14 PASS on the lab after the fixes (`output/regression/20260918T012644Z.txt`). The first CI run
of the workflow (35294125733) was launched before the review and is the recorded "before": it should fail at the check
step exactly as OB1 predicted; the push carrying these fixes starts the second. OB1's review was the decisive one — it
read the CLI binary for the success string, the workflow pair for `LAB_TRUST_ROOT` and `lab-route.sh`, and the demo
manifests for `probe-*`; Codex and Grok converged on the same script defects from the text alone.
