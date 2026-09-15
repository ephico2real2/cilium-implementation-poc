# Review — the bootstrap per host: `scripts/bootstrap/{ubuntu,macos}.sh`, `versions.env`, the three workflows

Adversarial second-opinion pass, 2026-09-15, on the 12-claim brief for commit `8434b6b` (branch `bootstrap-per-host`).
Codex (gpt-5.6-sol, xhigh) had a shell but no Docker daemon and no network to the release hosts; Cursor (Grok 4.6 high
fast, ask mode, shell blocked) traced from source and marked what it could not measure PLAUSIBLE. Each reviewer worked
on its own `git archive` export in its own scratch subdirectory; every verdict was re-checked here before a decision.
The fixes are commit `0789a08`; the runner measured the fixed head in run `35028933940`.

## Verdicts

| Claim | Codex | Cursor | Decision |
|---|---|---|---|
| C1 store-first when both settings files exist | CONFIRMED (4.35.0 release note) | PLAUSIBLE; proposed writing both files | **Rejected** (the dual-write) — see C1 |
| C2 the quit sequence and its 90 s guard | REFUTED: the guard re-checked only the backend | PLAUSIBLE; claimed `pgrep -x` cannot see an 18-char name | **Accepted** (Codex); Cursor's premise **refuted by measurement** |
| C3 heredoc inside process substitution on bash 3.2 | CONFIRMED (ran it on 3.2.57) | CONFIRMED (bash.1) | — |
| C4 the MemTotal window as the proof of the write | REFUTED: an old nearby setting passes | PLAUSIBLE | **Accepted** — the file after the rewrite is the proof; the window is the coarse check |
| C5 `verify` installs nothing unverified | CONFIRMED (6 cases) | CONFIRMED | — |
| C6 the "at the pin" parsers on the Linux binaries | PLAUSIBLE (no network) | PLAUSIBLE (no shell) | measured here: arm64 container twice, amd64 on the runner; the proposed test workflow **rejected** |
| C7 no early reader left under `pipefail` | REFUTED: `head -1` (l.59), `grep -q` (l.83) | REFUTED: `head -1` (l.59) | **Accepted** — both removed |
| C8 nothing else reads the removed pins; the actions did nothing more | CONFIRMED (kind.sh, action.yaml read) | PLAUSIBLE (web blocked) | — |
| C9 the `$GITHUB_ENV` export | CONFIRMED (6 lines) | CONFIRMED | — |
| C10 the pin self-check | CONFIRMED (edited copies: NO_MATCH) | CONFIRMED | — |
| C11 109 anchors, README's count | CONFIRMED | CONFIRMED | — |
| C12 the next real uses | CONFIRMED (mocked traces) | PLAUSIBLE: the rebooted-Mac path launches nothing | **Accepted** (Cursor) |

## C1 — which file when both exist

**Finding (Cursor).** The tree never measured a Mac with both files; if Desktop still read `settings.json`, store-first
would write the ignored file. Proposed: write the three keys into both files, each in its own spelling.

**Re-check.** Docker's release notes source (`content/manuals/desktop/release-notes.md`, under `## 4.35.0`):
"`settings.json` has been renamed to `settings-store.json`"; the current settings page names only the store's path.
Codex cited the same note.

**Decision.** Rejected: on any Desktop ≥ 4.35 the store is the file read, so a second write would go to a file
Desktop no longer reads; the legacy branch stays for a Desktop that still has only the legacy file (the Intel Mac's,
measured in the 2026-09-13 session).

## C2 — the guard after 90 s

**Finding (Codex).** The wait loop ended when both processes were gone, but the die on line 91 re-checked only
`com.docker.backend`: a GUI still alive with the backend gone let the script write the file and continue. Measured in a
mocked run: `rc=0`, settings written. **Finding (Cursor).** `MAXCOMLEN` is 16 on Darwin, so `pgrep -x com.docker.backend`
(18 characters) could never match; proposed `pgrep -f` on an alternation.

**Re-check.** `pgrep -x com.docker.backend` on the M5 returned three pids; `pgrep -x 'Docker Desktop'` one — macOS
pgrep matches the full name, Cursor's premise is refuted. Codex's defect is real: the two checks differed.

**Decision.** Accepted (Codex): one predicate `desktop_running()` — GUI or backend — used by the wait and by the guard.
Cursor's `-f` variant rejected (unneeded, and `Docker.app` would match every Desktop helper). Verified against a fake
`pgrep` that keeps only the GUI alive: the script dies before the write.

## C4 — what proves the write was taken

**Finding (Codex).** The window `[setting − 1536, setting]` on MemTotal passes when Desktop kept an old, nearby value
(24000 kept, 24576 asked: reported 23418 MiB is inside the window). Proposed: the keys read back from the file after
Desktop's rewrite must equal the values asked for; MemTotal stays a coarse sanity check with a wider window.

**Re-check.** Reproduced with a fake `docker info` and a file rewritten to 24000: the old code passed; the new code
dies with "MemoryMiB did not survive Desktop's rewrite … wanted 24576, found 24000"; the good case (24576) passes.

**Decision.** Accepted as proposed (window ¾ of the setting for the coarse check).

## C7 — the early readers left

**Finding (both).** `cilium version --client | head -1` in the "at the pin" echo (l.59) — `docs/VERIFICATION_RUN.md`
already records that exact pipeline exiting 141; and `id -nG | grep -qw docker` (l.83, Codex).

**Re-check.** Both present. The echo form does not abort the script (the simple command is `echo`), but the claim was
"none remain" and a later assignment form would.

**Decision.** Accepted: `awk 'NR == 1'` for the echo; a `case " $(id -nG) " in *" docker "*)` for the group.

## C12 — the rebooted Mac

**Finding (Cursor).** A Mac whose file is already right and whose Desktop is quit (`AutoStart` is false by default)
takes the "nothing to write" path, launches nothing, and the preflight prints `REQUIRED-FAIL docker` for a reason the
operator has to fix by hand.

**Re-check.** Traced: the launch lived only inside the write branch. True.

**Decision.** Accepted: before the preflight, when `LAB_VM_RESTART=1` and `docker info` does not answer, `open -a Docker`
and wait for the daemon (the `LAB_VM_RESTART=0` path still touches nothing, by design).

## Not asked, and what happened to it

- **Codex:** a fresh non-root Ubuntu install adds the user to `docker` and continues in a shell that does not have the
  group — the preflight then says "the daemon is not answering" for a reason nobody explains. **Applied**: the script
  stops there with the instruction to log in again and re-run.
- **Codex:** a `LAB_BOOTSTRAP_TOOLS_ONLY` mode and a new workflow on `ubuntu-24.04` + `ubuntu-24.04-arm` proving the
  no-download second run. **Rejected**: the measurement exists (twice in an `ubuntu:24.04` arm64 container here;
  amd64 on the runner in every run of the three workflows) and a review must not grow the code's surface.
- **Cursor:** `macos.sh` compared hubble's raw `$2` against the bare pin — a release binary on a Mac would print `≠`
  forever. **Applied**: the same `sed` strip as ubuntu.sh.
- **Cursor:** `ubuntu.sh` kept any helm on PATH — a Linux laptop with Homebrew's helm 4 never got the pin, although the
  header promised "one at another version is replaced". **Applied**: helm is a pin like the others (the runner's
  preinstalled 3.21.4 reads "at the pin"; measured in the container: installed on the first run, kept on the second).

## Outcome

Twelve claims: three refuted (C2, C4, C7), one PLAUSIBLE risk accepted (C12), one reviewer premise refuted by
measurement (Cursor's `MAXCOMLEN`), one proposed fix rejected on Docker's own release note (C1's dual-write), one
proposed test workflow rejected on scope. Four "not asked" findings, three applied. Re-validated after the edits: the
two guards against fakes (stuck GUI → die before the write; old value kept → die; good value → pass), `ubuntu.sh` twice
in a fresh `ubuntu:24.04` arm64 container (five pins + helm installed and verified, the second run downloading nothing),
`macos.sh` on the M5 (the already-configured path, exit 0, every preflight row ok), and the Action on the fixed head
(run `35028933940`).
