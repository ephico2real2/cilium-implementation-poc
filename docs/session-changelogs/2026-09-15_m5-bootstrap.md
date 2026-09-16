# Session change log — cilium-implementation-poc, 2026-09-15 → (open)

The first session on the operator's Apple M5 Pro, resumed from `docs/HANDOVER.md` (written the same day on the Intel
MacBook at `01f1c3d`). Times are git author times in America/Chicago; run ids are GitHub Actions'; every "measured"
claim is one the session ran a command for — nothing below is recalled from memory alone.

Outcome in one line: **…**

| | Before the session | After |
|---|---|---|
| The machine | the Intel MacBook (2019); the M5 Pro never ran the lab: `scripts/lab-preflight.sh`'s netkit and route rows unmeasured on Apple silicon (`docs/HANDOVER.md` §3) | |
| Docker Desktop on the M5 | 4.91.0 installed fresh, user mode, default VM (18 CPUs, 8 GB — `docker info` MemTotal 8,317,267,968); `settings-store.json` with 12 PascalCase keys and none of the three NEW-MAC §3 edits | |
| The host preparation | inline in three workflows (`helm/kind-action`, `cilium/cilium-cli`, a hubble curl, `tcp_bbr`) and by hand from `docs/NEW-MAC.md` §1–§3; the pins in three `env:` blocks and a table | |
| The Action | green, last run 34998586044 on `1e344ca` (44 m 32 s) | |
| Upstream | onzack/hubble-observer #16 open (one comment, ours, 20:33Z), onzack/cf2cnp #3 open (five comments, ours) | |
| Gotchas | 107 | |

---

## Part 1 — the M5's first preflight, and the bootstrap per host (2026-09-15)

### The M5's first commands, the preflight, and what it refuted (16:00 → 16:30) — no commit

- `docs/HANDOVER.md` §6 in order: `db5eb68` on `main`, clean; the Action's last three runs green (34998586044 latest);
  hubble-observer #16 open with one comment (ours, 20:33Z — posted after the handover was written), cf2cnp #3 unchanged.
- **Measured:** the M5 Pro (arm64, macOS 26.5.2, 18 cores, 64 GiB); Docker Desktop 4.91.0 installed fresh, engine
  `linux/virtualization-framework` (its backend log), user mode (`vmnetd is not installed on this system`); the VM at
  Desktop's default, 18 CPUs and 8,317,267,968 bytes; `settings-store.json` with 12 PascalCase keys and none of the
  three the guide edits. `scripts/lab-preflight.sh`: **REQUIRED-FAIL memory 7 GiB**, netkit **no**, route **warn**.
- **Found by the forensic pass, refuting two of the tree's own expectations:** (1) `docs/NEW-MAC.md` §3 wrote
  `cpus`/`memoryMiB`/`kernelForUDP` — the Intel Mac's legacy `settings.json` spelling; the store's names are the
  4.91.0 backend's Go fields `Cpus`/`MemoryMiB`/`KernelForUDP` (`strings com.docker.backend`; the UI addresses them as
  `vm.resources.memoryMiB`, `vm.network.kernelForUDP`), and absent keys are defaults. (2) Four docs promised netkit from
  Desktop ≥ 4.89.0 by kernel version; `/proc/config.gz` line 2033 of `7.0.12-linuxkit` reads `# CONFIG_NETKIT is not set`
  and `ip link add … type netkit` → `Attribute failed policy validation` while a veth pair is created. The Intel Mac's
  4.91.0 had never been launched, so this was the first 7.0.12 kernel read. Both retracted in the docs.
- **The operator:** "do we need this ==> no netkit" — no: `lab-observability.yaml` runs `LAB_FEATURES: ""` (veth) and
  every green run is veth; netkit is the runner spike's measurement (`lab-spike-kind.yaml`, `kernel-features`).
- **The operator:** "we need to have two types of bootstrap kind — some that is compatible with ubuntu and another that is
  compatible with macbook". The code confirmed where the split is: after Docker, one path (`lab-up.sh`, the configs, the
  values; `lab-preflight.sh` and `lab-route.sh` branch on measurement); before Docker, two paths, neither a script —
  inline steps in three workflows, and NEW-MAC §1–§3 by hand.

### The bootstrap per host (16:30 → 17:03) — commits `8434b6b`, `f68fc46`, `cd833cf`, branch `bootstrap-per-host`

- `scripts/bootstrap/versions.env` (the pins, one file), `ubuntu.sh` (the five pins from their releases with each
  published sha256 verified, helm at the runner's 3.21.4, docker.io when absent, `tcp_bbr`, the pins into `$GITHUB_ENV`,
  the preflight) and `macos.sh` (Homebrew's formulae, a versions table against the pins, the Docker Desktop VM from
  its settings file by the spelling the file uses — Desktop quit, three keys written with a backup and a diff,
  relaunched, the proof read back — then the preflight). The three workflows call `ubuntu.sh` in place of four steps
  and lost their `env:` blocks (−90 lines).
- **Measured:** `ubuntu.sh` twice in a fresh `ubuntu:24.04` arm64 container — first pass five `sha256 ok` + installs,
  docker.io 29.1.3; second pass every tool "at the pin", nothing downloaded. `macos.sh` on the M5: the diff shows exactly
  three lines added; the VM answers **CPUs=10 MemTotal=23,994 MiB**; the keys survive Desktop's rewrite; the preflight
  turns **memory ok 23 GiB, route ok — `eth1 192.168.64.2` on a host bridge, with no vmnetd**.
- **Found by me on the second pass, before the run:** SIGPIPE under `pipefail` — `cilium version --client | grep -m1`
  ended the script (exit 141); `hubble version` on Linux prints `v1.19.4@HEAD-…` so the pin compare re-downloaded every
  run; `docker version --format` prints an empty line before failing. All three fixed before the branch was pushed.
- **Found by CI:** nothing — run 35026560983 (`8434b6b`) green end to end, 43 m 13 s; the runner image already had kind
  at the pin (`helm/kind-action` used to fetch it regardless).
- **Adversarial review** (`docs/REVIEW_BOOTSTRAP.md`; Codex gpt-5.6-sol xhigh, Cursor Grok 4.6): 12 claims.
  **Accepted:** C2 the 90 s guard re-checked only the backend (Codex); C4 a MemTotal window passes an old nearby value —
  the file after Desktop's rewrite is the proof (Codex); C7 a `head -1` and a `grep -q` left (both); C12 a rebooted Mac
  with Desktop quit launched nothing (Cursor); not asked: the docker-group re-login stop (Codex), hubble's release form
  on the Mac and helm as a real pin on Linux (Cursor). **Rejected:** Cursor's dual-write of both settings files — Docker's
  release note under 4.35.0: "`settings.json` has been renamed to `settings-store.json`"; Cursor's `MAXCOMLEN` premise —
  `pgrep -x com.docker.backend` returns three pids here; Codex's test workflow on two runners — scope.
- **Measured after the fixes:** the two guards against fakes (stuck GUI → die before the write; old value kept → die;
  good value → pass); the container twice more (helm now installed on the first pass, "at the pin" on the second);
  `macos.sh` on the M5 exit 0; run **35028933940** (`f68fc46`) green, 43 m 41 s.
- Docs: gotchas #108 (the key names) and #109 (`CONFIG_NETKIT` unset on 7.0.12), README 109 traps; NEW-MAC header, §1,
  §3, §4; 004 phase 4's M5 table; SETUP Step 2's note; the runbook's acceptance test; `markdownlint-cli2` was missing on
  the M5 (installed; NEW-MAC §1 lists it).

### The lab on the M5 (17:45 → 17:55) — `scripts/lab-up.sh poc1 poc2`, the operator's go

- **The operator:** "you have the go". Run without `LAB_TRUST_ROOT` (the keychain needs a password this shell cannot
  give): **9 min 34 s**, exit 0; poc1 complete at +4:07, poc2 at +3:33; Cilium `OK`, KPR `True`, four arm64 nodes Ready;
  root `F4:FD:F8:B7…` identical in both; ClusterMesh `OK` both ways, `2/2 connected`, KVStoreMesh `1/1`. Gotcha #107's
  race hit (the Bundle at attempt 2). The first bring-up under Helm 4.3.0.
- Owed to the operator's Terminal: `scripts/lab-trust.sh install kind-poc1`, `scripts/lab-route.sh kind-poc1`.

---

## Part 2 — the labs on the M5, the same as CI, without the waits (2026-09-15, 18:05 → 19:45)

### Four passes to green — commits `93441ff`, `2c7e64b`, `92d7612`

- **The operator:** "so let deploy all the lab examples here — the same ones that we can ran in the github ci", then "we don't
  need the crazy wait time … make the wait time parameterizable such that we can pass what we want and override it".
  `scripts/lab-all.sh`: the Action's steps after `lab-up.sh`, with `LAB_AUDIT_MINUTES` (1; CI 3) and `LAB_TRAFFIC_MINUTES`
  (0 = skipped; CI 6) as knobs, `LAB_CAPTURE`, `LAB_OBI`, `LAB_SKIP`. The facts behind the defaults: `lab-apps.sh all`
  already exercises every lab once; the chapters need only flows that exist; `rounds`/`traffic` feed the dashboards'
  5-minute panels and CI's strict data wait.
- **Pass 1 (CI-shaped driver, 18:09 → stopped at the audit step 18:16).** The Gateway (`172.18.255.241`, HTTP 500 before
  routes — the runner's line too), the Hubble UI 200, poc2's `rebel-base-lb 172.18.255.136` 200 from this Mac; images in
  24 s. **Found by the Mac:** `ModuleNotFoundError: No module named 'yaml'` — `dashboard-from-file.sh` printed its
  ConfigMap with PyYAML, which GitHub's image has and macOS's python3 does not; under `set -e` the stack stopped there
  (OBI, the CLI certificate, Kyverno never ran) and demo 30's `hubble observe` ended the labs. **Fixed:** JSON out
  (`kubectl` reads both; proven with a client-side dry run: uid pinned, 13 panels, `__inputs` dropped); gotcha #110.
- **Pass 2 (18:36 → stopped 19:13).** **Found by the Mac:** `declare: -A: invalid option`, `c[@]: unbound variable`, the
  petclinic silent — macOS's `/bin/bash` 3.2.57; the runner has 5.2. **The operator:** "make installing homebrew … and
  then install bash from homebrew part of the setup of this lab on macbook and say it is a requirement." **Fixed:**
  `brew install bash` (5.3.20; `/opt/homebrew/bin` precedes `/bin`), `macos.sh` installs Homebrew itself (the
  installer's unattended mode after `sudo -v`, read from its source) and the formula, a `bash (env bash)` preflight row
  (REQUIRED-FAIL < 4.4), NEW-MAC §1 and SETUP Step 1 state the requirement; gotcha #111. Then the bank's check sat 36
  minutes: **found by the agent's flow log** — `forensic/client → bank/api Policy denied DROPPED`; the cell from pass 1
  was still there and the check runs "before the cell"; and the `timeout 15m` guard (written after the runner's own
  94-minute hang) is GNU coreutils' — absent on macOS, the guard fell through silently. **Fixed:** the bank lab removes
  the cell (the CCNP and the `rendered-from=intent.yaml` policies) before the check; a `deadline` helper
  (`timeout`/`gtimeout`/a spoken warning); `coreutils` a requirement; gotcha #112.
- **Pass 3 (19:14 → 19:20, 5 min 43 s).** The bank check **`TOTAL ok=282 fail=0 poc1=83 poc2=199`** in 1 min 55 s (the
  runner: 2 min 38 s). **Found by the Mac:** the petclinic died at its header — `free -m` is Linux's, the failed pipeline's
  status was the assignment's; chapter 26 found `no AUDIT flow pos → shop` — pass 1's generated allow still forwarded it.
  **Found by me, my own doing:** a `syntax error` in `rounds` — I had patched `lab-apps.sh` while it was executing.
  **Fixed:** `used_mb()` optional; `reset_chapter` (delete the `app.kubernetes.io/managed-by=cf2cnp` policies; lab30 also
  chapter 30's default-deny) in labs 26, 27, 30, 35.
- **Pass 4 (19:21 → 19:30, 9 min 5 s): every step passed.** Labs 3 min 27 s (the bank `ok=281 fail=0`, the petclinic's
  Eureka 4 UP, `memory: host used ?(no free on this host)`), one audit minute, six chapters regenerated on reset
  namespaces, the report's 13 checks with 0 trouble words each — the runner's rows, one for one (run 35028933940 had 1
  in demo 25 Part 5).
- **Adversarial review** (`docs/REVIEW_LABS-ON-MAC.md`): 11 claims. **Accepted:** C1 the label also selects demo 31's
  recorded policy (both; a comment), C4 the ceiling warning was redirected into the check's file (Cursor), C8 the
  installer refuses Intel macOS (Codex, read in the source) and sudo's timestamp can expire mid-install (Cursor); not
  asked: `LAB_STACK_PEER_CTX` (Codex), the JSON header (Cursor). **Rejected:** Cursor's name-based delete and re-labelling
  of the committed demo-26 examples — the lab applies only what cf2cnp 0.7.0 generates, and it labels. Verified against
  fakes; the gate on `93441ff` (run 35040355665) and on `2c7e64b` (run 35041617666).

---

## Part 3 — cf2cnp's API page (2026-09-15, 19:55 → 20:50) — the fork, branch `feat/api-page-try-it-out`, `fb81ce6`, `ae0664a`

- **The operator:** three concerns on `cf2cnp.poc.local` — the endpoint cards not clickable, the version not shown near
  the logo, "Try it out" a separate section rather than Swagger-like under each endpoint, pre-populated. Then: "make sure
  to push this to remote feat/api-page-try-it-out after fixing any gotcha … I need you to use cursor more for agentic
  coding and you claude code orchestration"; then "you are still gonna use our skills" (both saved as the memory note
  *cursor-does-the-coding-claude-orchestrates*).
- **What changed** (`internal/server/server.go`, `server_test.go`, `cmd/cf2cnp/main.go`): `main.version` reaches the
  server (`Options.Version`; `displayVersion` for the three build shapes) and shows as a badge beside the logo and in the
  title; each endpoint a native `<details>` card; a Try-it-out panel under each — `/generate` with the unchanged form and
  the example loaded on first unfold, `/download/{id}` pre-filled from the last generate's `download_url`, `/health` —
  each answering `HTTP status · ms · content-type` and the body. **Cursor (agent mode, from a brief naming lines, change,
  constraints, tests):** the checkboxes inline with their labels (the `.controls input` rule had made them full-width
  blocks — on the live page too), the curl examples on `baseURL(r)` instead of `localhost:8080`, two tests. **Me:** the
  plumbing, the cards, the panels, the tests, and what the browser exposed.
- **Measured in Chromium (Playwright, the lab's own install):** the badge rendered as an **empty pill** — the `h1`'s
  `-webkit-text-fill-color: transparent` inherited; fixed. A flex label wrapped "Layer-7 rules" onto two lines; fixed
  (inline flow). Then: three cards, none open at load; `/generate` unfolds and pre-fills 1,150 chars; generate → a
  policy, the download id populated; `/download/{id}` Send → `HTTP 200 OK · 14 ms · application/x-yaml`; `/health` →
  `HTTP 200 OK · 15 ms`; a second click folds the card. At 390 px: no horizontal overflow; Tab reaches each card, Enter
  unfolds it. **Found by me, my own doing:** `pkill -f cf2cnp-tryout` matched the compound command that was about to
  restart the server, so the served page was the old binary for one capture — restarted by pid thereafter.
- **`frontend-design`** (installed on the M5 with `npx skills add mager/frontend-design`): the restyle path — a 200 ms
  border/glow transition on hover and `:focus-within`, a `:focus-visible` ring on the summary, the brief wrapping under
  the path at phone width (`ae0664a`).
- The live comparison the operator asked for: `http://cf2cnp.poc.local/` (image `ghcr.io/ephico2real2/cf2cnp:0.7.0`)
  captured with Playwright — the same form controls as the new page, element for element; both captures sent.
- Pushed to the fork's `origin`; `develop` and upstream PR #3 untouched; no PR opened (the operator's word). The lab still
  serves 0.7.0 — the dev deploy to `cf2cnp.poc.local` awaits the operator's call.
- **Adversarial review** (the fork's `docs/REVIEW_API-PAGE.md`; Codex + Cursor, 8 claims): **C3 refuted by both** — the
  branch's own line put `baseURL(r)` into the HTML unescaped and `validHost` lets `<>"` through: a reflected XSS via
  `X-Forwarded-Host` (measured before: `<svg>` served raw; after: `https://&lt;svg&gt;/generate`); **C4** (Codex) — a flow's
  `uuid` is the cache key, so `..` made `download_url` end in `/download/..` (`validDownloadID` now); **C5** (Codex) —
  whitespace-only text overwritten by the example; **not asked** (Codex) — the card said "an hour", `cleanupCache` says 10
  minutes: my text, unread. **Rejected:** Cursor's tightening of `validHost` (changes `download_url` for every caller —
  wrong layer), Codex's release-workflow change for a `vnext` tag (not a version). Cursor implemented the four fixes from
  a brief; the diff read, the suite green, both security fixes measured on the rebuilt binary. `1cbfabd`, pushed.
- **The operator:** Google AI's consolidated-ingress suggestion — **measured on poc1** in a scratch namespace: both YAML
  shapes compile to the same eight BPF policy-map entries (`cilium-dbg bpf policy get 1946`: `Allow Ingress 112713 80/TCP`,
  `Allow Ingress 81702 80/TCP`), so "BPF map efficiency" is refuted; the per-peer rule is what lets peers differ in ports
  and L7 rules and what `merge` and 27 goldens depend on. **The operator:** "don't add it" — no `--compact`, no README line.
- **Swagger UI + ReDoc for cf2cnp** — proposed the group-sync-dashboard way (vendored, npm-integrity-checked, a drift
  test); **the operator:** "is this worth it?" — no: three endpoints already documented with Try-it-out, a hand-kept spec
  would be a fourth description, ~2.5 MB of JavaScript; "park this idea" → README *Parked* and the fork's issue #4
  (the plan verbatim, the condition to revisit), cross-linked.
- **The fork's PR #3** (`feat/api-page-try-it-out` → `develop`) opened on the operator's word; the review skill's **second
  pass** on `1cbfabd` (9 claims; the record's second section): **refuted** — `/download/a/b` still reached `cache["a/b"]`
  in `handleDownload` (Codex), a second generate left the previous download's status and body on the panel (Codex),
  "open in a new tab" 401s on a token-guarded server — a navigation carries no bearer header (Codex, and Cursor's
  volunteered finding), the card's "the first time this unfolds" was not what the code did (Codex refuted / Cursor
  "intended": a text fix). Behind the Gateway, the tests-with-fixes-reverted and curl users: confirmed. Cursor implemented
  the four from a brief; measured on the rebuilt binary (404, the cleared panel, the hidden link). `1be56f1`, pushed.

## Part 4 — cf2cnp 0.8.0: the release the merge did not make, and the lab on it (2026-09-16, 05:40 → 06:45)

- **The operator merged fork PR #3** (05:40:30Z, `349c32a`) and asked why no image and no chart followed. Measured from
  the workflow triggers: a push to `develop` runs `ci.yml` only (run 35060458490, success); `docker-publish`,
  `helm-publish` and `binary-release` fire on a **tag** (or `main`, which the fork never uses), `chart-releaser` on a
  `develop` push touching `helm/**` — PR #3 touched `internal/server/*` only. That is how 0.7.0 was cut on 2026-09-13
  (`d3819ca` bumped `Chart.yaml`, tag `v0.7.0` at `3144152`). **The operator:** "i am okay with public release 0.8.0".
- **The release** — Cursor from a brief: `Chart.yaml` 0.7.0 → 0.8.0 and the `## 0.8.0 — 2026-09-16` changelog entry;
  one number corrected by measurement (my brief said 27 goldens; `ls internal/testdata/golden` and `go test -run Golden`
  both say 14). `f00b9c6` + tag `v0.8.0` pushed → image (run 35061570383, linux/amd64 + arm64), OCI chart
  (35061570406, `oci://ghcr.io/ephico2real2/helm-charts/cf2cnp:0.8.0`, digest `b748391…`), gh-pages index
  (35061568941, `created 2026-09-16T05:57:05Z`, `a088437`), binaries + checksums (35061570394, 05:58:52Z), CI green.
  The gh-pages README (`8bdd196`) records the five workflows, their triggers and each artefact's path with 0.8.0's proof
  — the operator asked for the table there; the v0.8.0 release notes carry the changelog entry and the same table
  (`gh release edit`, on the operator's word).
- **The lab on 0.8.0** — `values-hubble-observer.yaml` `tag: "0.8.0"`, `lab-policies.sh` `CF2CNP_VERSION` 0.8.0 (the
  binary downloaded and its checksum verified on the M5: `cf2cnp 0.8.0`, spec Cilium v1.20.1); `chart-from-fork.sh
  develop` → release revision 3, the cf2cnp pod on `:0.8.0`. Measured through the Gateway (172.18.255.240, http and
  https): title and badge `v0.8.0`, three cards, `/health` OK, `/download/a/b` 404; in Chromium the `/health` panel
  answered `HTTP 200 · 15 ms · text/plain`. `9587a64`.
- **Gotcha #113 — my wrong step, the operator's rule.** I `kind load`ed the pulled image first; it failed
  (`ctr: content digest … not found`: under Docker's containerd image store the tag is a multi-platform index and the
  import asks for the amd64 manifest never fetched, kind #4224/#3795), and the `docker save --platform` archive route
  worked — but the step was unnecessary: 0.7.0's pod carries a ghcr `repoDigest`, the nodes pull the public package
  themselves. **The operator:** "kind can pull public images, we only need load if this image was built locally".
  The gotcha is written that way round; the values comment that had claimed the package was private is corrected.
  113 traps in README.

## Part 5 — the two READMEs (2026-09-16, 07:10 → 08:10)

- **cf2cnp's README (fork PR #5, `docs/readme-0.8.0-web-ui`)** — six Playwright screenshots of the deployed 0.8.0 page
  in a *The web UI* section (the page; 24 of demo 30's flows pasted with L7 on → `24 flow(s) → 2 policies`; `/download`
  by the filled-in id, `HTTP 200 · 17 ms`; `/health`; a refusal — the only real one the page can show, a name over two
  policies, HTTP 400). Cursor from a brief did the edits; one number in my brief corrected (14 goldens, not 27). The
  review of the README itself: versions to 0.8.0, the merge paragraphs back under 1b (scattered under fromCIDR with a
  duplicate block and an empty fence), `serve`'s two missing flags, `/generate`'s five query parameters, the output
  examples regenerated with the 0.8.0 binary (names, `managed-by`, the description, `ANY/53`), one CSS selector so the
  download and health panels wrap like the generate result. **The operator:** "it is forked project so i cannot use my
  own link here … it needs to reflect the upstream project once we opened a PR" — the Fork note and the running-test
  captures paragraph (both on `develop` before this PR) removed, the clone and binaries URLs name onzack/cf2cnp, the fork's
  artefacts moved to the gh-pages README's *Testing the fork* (`1ba227a`). Flagged in the PR: `CHANGELOG.md` and the spec
  table's fork versions are on `develop` too.
- **"No contributors" on the fork** — measured: the sidebar says so on both forks (cf2cnp, hubble-observer) and shows
  names on both non-forks; the API lists `ephico2real2 53, R-Studio 6, lucatr 1`; GitHub populates the widget for the
  parent only. Nothing to fix.
- **This repository's README (branch `readme-restructure`, PR pending)** — **the operator:** "this is not well
  structured — it can be better, summarize where appropriate, put Cilium documentation as references for features that
  were tested"; chose the full restructure. Measured first: 26.4 screens, 9,692 words, 0 images, the demos enumerated
  four times, "All ten demos" and "14 sections" stale. Rewritten to ten sections (12.8 screens before the review's
  additions; 4,532 words; one image; one demo table 01→36 in six groups with the evidence beside each; a *Cilium docs*
  column, every URL fetched — `security/policy/language/` is a 200-status redirect stub, the real page is
  `security/policy/`). My own second pass restored six things the condensing dropped; Cursor and Codex (read-only, own
  scratch copies) refuted all three claims and were re-checked: six facts restored, three deliberate corrections kept,
  four docs rows fixed, one Cursor claim refuted by the pages (the audit-mode anchor is on `policy-creation/`, not
  `lifecycle/`). Record: `docs/REVIEW_README.md`. SETUP's link into the removed *Findings* anchor repointed.
- **The lab, on request** — "does flow expire?": no; the download entry does (10 min, in-memory, and the 06:30 pod
  replacement emptied it). Ten minutes of every lab's traffic (`scripts/lab-apps.sh rounds 10`), a fresh flow
  `b5145c22…` → a live `download_url` (HTTP 200 at 07:52:20Z). "do we need to persist data?" — no: the YAML is in the
  JSON answer; persistence is the file in git.
