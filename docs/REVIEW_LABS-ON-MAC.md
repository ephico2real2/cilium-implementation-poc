# Review — the labs on a laptop: `scripts/lab-all.sh`, the re-run and platform fixes in `scripts/lab-apps.sh`, the Mac's requirements

Adversarial second-opinion pass, 2026-09-15, on the 11-claim brief for commit `93441ff` (branch `bootstrap-per-host`,
PR #12's second batch: what the M5's four passes found). Codex (gpt-5.6-sol, xhigh) had a shell, PyYAML and both sorts;
Cursor (Grok 4.6 high fast, ask mode) had every shell call rejected and traced from source, marking the rest PLAUSIBLE.
Each reviewer worked on its own `git archive` export; every verdict was re-checked here. The fixes are commit `c6f2d97`;
the runner measured the batch in run 35040355665 (`93441ff`) and the fixed head in run `35041617666`.

## Verdicts

| Claim | Codex | Cursor | Decision |
|---|---|---|---|
| C1 `reset_chapter` removes only generated policies | REFUTED: demo 31's recorded `cnp-pos-fqdn.yaml` is labelled and lab-applied | REFUTED: the same, plus the committed demo-26 examples are unlabelled | **Accepted on the fact (comment)**; Cursor's name-delete and re-labelling **rejected** |
| C2 lab30 removes chapter 30's default-deny | CONFIRMED | CONFIRMED | — |
| C3 the bank removes the whole cell | CONFIRMED (7/7 labelled, the CCNP name) | CONFIRMED | — |
| C4 `deadline` three ways, status preserved | CONFIRMED (fakes: rc=7 all three) | PLAUSIBLE: the warning lands in the redirected file | **Accepted** (Cursor) |
| C5 `used_mb` on both hosts | CONFIRMED (321/321; empty + the fallback text) | PLAUSIBLE | — |
| C6 JSON ConfigMap ≡ YAML ConfigMap | CONFIRMED (1 MiB dashboards, byte-equal data) | PLAUSIBLE | — |
| C7 the bash row's parsing and ordering | CONFIRMED (BSD and GNU sort; 4.3.99 fails, 4.4.0 passes) | PLAUSIBLE | — |
| C8 the Homebrew install sequence | REFUTED: the installer refuses Intel macOS | PLAUSIBLE: sudo's timestamp can expire mid-install | **Both accepted** |
| C9 `lab-all.sh`'s knobs | CONFIRMED (0/positive/skip word-match/verdict/sum) | CONFIRMED | — |
| C10 the runner's path unchanged | PLAUSIBLE (helpers measured; a cluster needed) | PLAUSIBLE | run 35040355665 is the measurement |
| C11 112 anchors, README twice | CONFIRMED | CONFIRMED | — |

## C1 — what the label selects

**Finding (both).** `reset_chapter` deletes by `app.kubernetes.io/managed-by=cf2cnp`. Demo 31's recorded
`cnp-pos-fqdn.yaml`, which `dns()` applies, carries that label (cf2cnp wrote it), so `lab26`'s reset removes the DNS lab's
policy. Cursor added: the committed examples under `demos/26-cf2cnp-policy-from-flows/policies/` carry no label, and
proposed deleting `shop` and `pos` by name and re-labelling those files.

**Re-check.** Both facts true. But the lab never applies the committed examples — the chapters generate with cf2cnp 0.7.0,
and every generated file in `captures/policies/*/` on the M5 carries the label (Cursor's export had no `captures/`).
In `all`, `dns` runs after `lab26` and re-applies the recorded policy; only a standalone `lab26` after `dns` loses it.

**Decision.** Accepted on the fact: the function's comment names the demo 31 interaction (Codex's wording). Rejected:
the name-based delete (a namespace-specific special case for objects the lab does not create) and the re-labelling of
committed files (recorded output stays as recorded).

## C4 — where the warning goes

**Finding (Cursor).** The only caller redirects the check's stdout and stderr into `captures/checks/demo15-check.txt`, so
`deadline`'s `::warning::` about a missing ceiling never reaches the log — the same silence gotcha #112 names.

**Re-check.** True: line 142 is `( … deadline 15m … ) > file 2>&1`.

**Decision.** Accepted: the bank lab prints the warning before the redirect when neither `timeout` nor `gtimeout` exists;
`deadline` keeps its own for other callers.

## C8 — the installer's two contracts

**Finding (Codex).** `install.sh` (HEAD): "On macOS, support Apple Silicon only … abort 'Homebrew on macOS is only
supported on Apple Silicon processors!'" — the bootstrap cannot install Homebrew fresh on the Intel Mac it names.
**Finding (Cursor).** `NONINTERACTIVE=1` turns every `sudo` into `sudo -n`; `sudo -v`'s timestamp is 5 minutes by default,
and the Command Line Tools install can outlast it → "Need sudo access on macOS" mid-install.

**Re-check.** Both read in the installer's source (lines 168–172; `have_sudo_access`). An Intel Mac with an existing
`/usr/local/bin/brew` is still found by `brew_env`.

**Decision.** Both accepted: an arm64 guard before the installer with the instruction for Intel; a `sudo -n true`
refresher every 50 s while the installer runs, killed (loop and its sleep, by pid) when it returns; `|| rc=$?` so `set -e`
cannot exit before the kill. Verified against fakes: the Intel path dies before `sudo`/`curl`; a failing installer names
its exit and leaves no process behind.

## Not asked, and what happened to it

- **Codex:** `lab-all.sh` read `LAB_PEER_CTX` while `lab-stack.sh`/`lab-apps.sh` read `LAB_STACK_PEER_CTX` — a custom peer
  would split the steps between two clusters. **Applied** (measured: `LAB_STACK_PEER_CTX=kind-custom` → `PEER=kind-custom`).
- **Cursor:** `demos/16-monitoring/dashboard-configmap.sh`'s header still said "Prints the ConfigMap YAML". **Applied.**
- **Cursor:** `dns` then `lab26` undoes the DNS lab — the same fact as C1, covered by the comment.

## Outcome

Eleven claims: two refuted (C1 by both, C8 by Codex), two PLAUSIBLE risks accepted (C4 the warning's destination, C8 the
sudo timestamp), Cursor's C1 fix rejected on what the lab actually applies, three "not asked" findings, all applied.
Re-validated: the reworked blocks against fakes (Intel guard, failing installer, keep-alive cleanup by pid, the peer knob,
the warning's placement); the runner's gate on `93441ff` (run 35040355665) and on the fixed head (run `35041617666`).
