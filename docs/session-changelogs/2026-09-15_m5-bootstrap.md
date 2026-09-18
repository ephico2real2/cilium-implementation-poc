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

## Part 6 — the Grafana action's real cause, the Gateway's two models, the spoke (2026-09-16, 08:10 → 11:20)

- **"An error has occurred" on the dashboard's Generate action — found.** Every server-side layer measured clean (the
  API replayed with curl → 200, the same action from an `https://` page → 200, the root in the keychain, CORS for the
  https origin); the operator's pasted URL began with **`http://`**. Reproduced from that exact URL in strict-TLS
  Chromium: `POST https://cf2cnp.poc.local/generate FAILED IN THE BROWSER: net::ERR_FAILED` — the preflight for
  `Origin: http://grafana.poc.local` has no allow-origin. Along the way, two claims retracted in words: "your click never
  reached cf2cnp" (cf2cnp logged no refusals at all — the gap PR #6 closed) and my own `:8080` probe of the Service
  (the Service is `:80`; the SYN went out as `(world) to-network`).
- **cf2cnp 0.9.0 — structured logging** (fork PR #6, `docs/REVIEW_LOGGING.md`): `log/slog`, `--log-format`/`--log-level`,
  one `request` line per call with a request id (Envoy's `X-Request-Id` kept), every refusal a `refused` line with a
  reason, `/download` 404 / 410 / 200. Two reviewers refuted three claims (the raw query logged, a panic skipped the
  line, 24 h tombstones) — fixed with tests that fail on regression. Tagged `v0.9.0` and redeployed (lab PR #15); the
  live log then narrated the operator's own Download-before-Generate as `reason=download_unknown`. Left: the observer
  fork's `Chart.lock` pins the cf2cnp subchart at 0.7.0, so 0.9.0 logs in text — a dependency bump when wanted.
- **"Grafana needs the CA? use the Service name?"** — measured, no and no: the Grafana *server* never calls cf2cnp; a
  browser cannot call `http://…svc` from an `https://` page (`mixed-content`) and cf2cnp's own policy drops in-cluster
  callers (`Policy denied DROPPED`). Grafana 13.2.1's data-source proxy refuses arbitrary POSTs. The same-origin
  Gateway route is the way to make it internal — **issue #14**, step 0 done below.
- **The Gateway, TLS-only and two ownership models** (PRs #16, #17; gotcha #114; demo 09 Part 2's *Listeners and
  `sectionName`*): the Grafana route had no `sectionName` and so served on `:80`; the serving route pinned to
  `https-wildcard`, a 301 route on `http`. Then the kube-prometheus-stack chart's own `grafana.route.*` values render
  both routes into `monitoring`, and `routes-gw` admits namespaces by label (`gateway-access: routes-gw`) — the Gateway
  API's second model beside the ReferenceGrant one; `10-gateway.yaml` kept as the hand-written example, marked not
  applied. Measured: an unlabelled namespace's route → `NotAllowedByListeners`; a wrong `sectionName` → `NoMatchingParent`.
- **The README** (PR #13 rebased over a conflict, PR #18 the Quick start as a list — the operator's screenshot showed
  the comment column overflowing); **the models table** in the review skill with the two Claude Fable 5 reviewers and
  the ZDR trade (group-sync-dashboard PR #137, memory `cursor-fable-reviewer`).
- **Both clusters on one dashboard** — the Hubble UI already did (`?namespace=bank`, mesh-wide relay 4/4); Grafana
  showed poc1 only because demo 22's spoke was not in `lab-stack`. New `spoke` step (PR #19): poc2's Prometheus
  remote-writing to the hub, Cilium metrics on poc2, the step proving itself from the hub. M5: 41 s; runner (run
  35085443771, green): 51 s, +0.9 GB (9,705 MB used after the stack vs 8,783). `LAB_SPOKE=1` default. No Grafana on
  poc2 by design (a data source, not a UI) — a standalone-spoke variant noted for demo 37's isolation theme.
- **Demo 37 groundwork, measured before the plan:** on Cilium 1.20 a Gateway is a Service + listeners on the shared
  per-node `cilium-envoy` DaemonSet — not its own proxy — so a namespaced Gateway buys address, listeners, certificates
  and ownership, not CPU isolation; the noisy-neighbour test will be a real measurement. `gateway-pool` selects any
  Gateway-owned Service, whatever the namespace. Next: the issue and `enhancements/005`.

## Part 7 — demo 37 built and measured; the dashboards told the truth (2026-09-16 11:30 → 2026-09-17 15:30)

- **Demo 37 phase 1** (PR #23): two doors on poc1 — `team-a` on `routes-gw` by label, `team-b`'s own Gateway at `.243`
  with a cert-manager wildcard for its zone `*.team-b.poc.local` (the operator's question — measured: Gateway API
  wildcards are multi-label, TLS wildcards single-label, so the zone is the second wall behind the admission policy),
  the platform's Role (`edit` cannot create gateways/httproutes — measured), one backend behind both doors through a
  ReferenceGrant, the zone's 301 route (check.sh caught it covering one name). The negatives: the flat hijack served with
  a valid certificate, the zoned one failing TLS, the policy refusing it by name. `hosts-entries.sh` without wildcards.
- **The apps answer a browser** (PR #24, the operator: "so that I don't have to toggle pretty", then "not visually
  pleasing", then "some colour, not bright", then "why didn't you make it a function"): Accept negotiation, a muted
  palette, and one shared module `demos/shared/jsonview` required by both apps with the build context moved to `demos/`;
  compact JSON unchanged byte for byte. My miss: a `grep -c` returning 0 broke an `&&` chain and skipped a rebuild once —
  caught by the image's build time.
- **Demo 37 phase 3** (PR #25): fortio, six phases × three runs, the confounders the review named recorded per run.
  Two rig faults found by the numbers and kept: in-cluster clients are served by their **own node's Envoy** (the first
  rig's load and probe never shared a process: 0.3–0.85 vs 0.01 cores), and sequential probes fell outside the load
  window (retracted). The result: a team's Gateway does not isolate it on Cilium — a probe on either door slows ×4–5
  whichever door is loaded; two tenants get exactly half each (11.5k of 24.5k qps) through two doors **or one** (the
  operator's same-door question); the node is not the limit (117k qps direct); ~45 M requests, 0 errors. The operator:
  "the results being stable is also good for Cilium" — yes, and quantified. The host as a variable: CRC beside the VM
  doubled the tails (p99 30–60 vs 17–23 ms). **The operator ran CRC** (`~/gitRepos/crc-up.sh`, written for them; the
  arithmetic 24 + 32 of 64 GB said out loud) and stopped it before the last run.
- **Gotcha #115** — Hubble's `destination_workload` filled only for a backend local to the reporting Envoy (eleven
  series, `kube_pod_info` placement; demo 16 Part 9 had met it for the contexts) → Cilium's *L7 by Workload* dashboard
  blind to most Gateway traffic. **The fix from the written sources** (PR #26, `docs/HUBBLE-L7-LABELS.md`): `source_app`
  / `destination_app` in `labelsContext` (the reference's own lever; `context.go` at v1.20.1 confirms), both clusters;
  **gotcha #116** — the dynamic config refuses a label-set change on a live metric (the error every 10 s, `rollout
  status` meaningless) → agents restarted, Gateway off the air ~45 s; `l7-by-app-dashboard.py` rewrites the chart's
  dashboard onto the app labels (CPU panels dropped; `allValue .*` — the Gateway's empty `source_app` never matched
  "All", in Cilium's dashboard too), provisioned by lab-stack. **Aligned:** 500 qps per door → 499.9 / 499.94 req/s by
  app, 0 / 0 by workload. Hubble's sub-5 ms percentiles are its first bucket, named.
- **The `cluster` gaps the operator spotted** ("namespaces, pods, but no cluster"): *Hubble Metrics and Monitoring* had
  no cluster variable and summed both clusters since the spoke — a per-cluster copy on all 35 queries, measured
  259.6 = 212.2 + 47.4 (PR #27, demo 22 Part 6); the observer flow table's cluster fields were parsed then excluded —
  two columns and a stray rename fixed on the fork (ephico2real2/hubble-observer#1, for the operator to merge).
- **Merges on the operator's word** ("merge and do your thing"): #25, #26 (rebased over #25's gotcha), #27. The upstream
  Cilium report is drafted in `HUBBLE-L7-LABELS.md` §7, posted only on the operator's word.

## Part 8 — contributing upstream, written down; the agent image rescanned (2026-09-17 12:30 → 16:15)

- **`docs/upstream/`** (PR #29, the operator: "what is cilium/cilium? … step by step a junior engineer will understand
  … benefits and screenshots … it is okay to override what we have"): what the repository is and where the chart, the
  dashboards, the metrics reference and the metrics code live; their contributing guide quoted (issue first, fork, DCO
  `git commit -s`, `Fixes:`, the release-note block, labels, CODEOWNERS, `/test`); the L7 dashboard change end to end
  with the before/after screens, the data path, the capture, the fix, the alignment (499.9 vs 0), the bug report field
  by field and the PR as it would be written; `l7-by-app-dashboard.py --upstream` produces the chart-shaped file (same
  title/uid, the CPU panels kept on kube-state-metrics variables), verified in Chromium under load and checked in with
  its diff. **Their AI policy** (PR #30, the operator: "they also have an AI standard now"): `cilium/community/AI-POLICY.md`
  quoted — declare non-trivial AI use and the human review applied; the DCO certifies the person — and the lab's
  declaration paragraph. Memory: `upstream-cilium-collaboration.md`.
- **The rescan** (PR #31, the operator: "our last scan has a lot of bugs — rescan, list the results, take a screenshot,
  another file under docs/upstream"): trivy 0.74.0 and grype 0.119.0 on `v1.20.1` (the lab) and `v1.20.2` (released
  09-16). **128 → 13 HIGH, 0 CRITICAL both.** The 128 read as one cause — eight Go 1.26.5 stdlib CVEs × fourteen Go
  binaries = 112 — plus x/text ×8, grpc ×6, x/crypto ×2; 1.20.2's Go 1.26.8 removed 115. The 13 traced to owners:
  `pebble` (8) is the **Ubuntu 26.04 base rootfs's** binary — no dpkg owner, not built by `images/runtime`, never started
  (the image `Cmd` is `cilium-dbg`, the DaemonSet's command `cilium-agent`); Cilium pins `ubuntu:26.04@513c0741…`
  (09-01) and the current digest `cd21a4f6…` (09-12) scans 0; grpc 1.83.2 and x/crypto 0.55.0 are **missing on the
  `v1.20` branch** because Renovate's #48575 was autoclosed five minutes after opening while `main` and `v1.18` merged
  theirs. The packages the two CVEs live in (`x/crypto/ssh`, `grpc/xds`) do not appear in the stripped binaries — a
  `strings` contrast against sibling packages of the same modules (59/56/56 `cryptobyte.` vs 0). Two issue drafts in
  §6, **posted only on the operator's word**; the trivy tables checked in; the screenshot rendered from them.
- **Review** (`docs/REVIEW_IMAGE_SCAN.md`): Codex (xhigh, with the JSON and the three binaries) reproduced every count
  and refuted one sentence — "the entrypoint is `cilium-agent`" (it is `Cmd: /usr/bin/cilium-dbg`, no Entrypoint;
  fixed, the DaemonSet's command measured on poc1); Grok caught `hubble` wrongly listed for x/crypto, the histogram
  printed for one binary of three, a repository search standing in for the binary check, and "not exploitable" saying
  more than the evidence — all applied.
- **Recommended, not performed:** the lab to Cilium 1.20.2 (`CILIUM_VERSION` in `lab-stack.sh` and `lab-preflight.sh`,
  the README's versions table) — an agent rollout per cluster, gotcha #42. Merged under "merge and do your thing":
  #29, #30, #31. Still for the operator: hubble-observer#1, cf2cnp#5, the two upstream posts, the upgrade.

## Part 9 — what is new in 1.20.2; the release-notes skill; both clusters moved (2026-09-17 16:20 → 18:30)

- **"What is new in 1.20.2 and how can it benefit us?"** — read from the release itself (`gh release view v1.20.2`,
  published 09-16 01:53Z): 1 minor, 39 bugfixes, 28 CI, 68 misc, 2 other — 138 bullets. Six with a side in this lab
  (the L2 VIPs with `externalTrafficPolicy: Local`, policy revision for new pods = the connectivity test's setup flake, a
  policy-recompute crash under churn, per-listener `Programmed`, Hubble's drop rate limit, Cluster Mesh's remove path);
  the rest not for us with the value that proves it. One written constraint retired (enhancement 005's "Local is
  incompatible with L2" → fixed in 1.20.2, cilium/cilium#46399; still no Gateway isolation, Envoy is on every node).
- **The skill the operator asked for** (PR #33): `.claude/skills/upstream-release-notes/SKILL.md` — fetch, compare in
  the lab's files (a table of where each feature lives), eight report sections, act within the standing rules — and
  `scripts/upstream-release-notes.sh` (Cursor/Grok from a brief, after one silent 0-byte run; relaunched with stdin
  closed): the release verbatim with section counts and keyword hits per lab feature, the lab's pins grepped; for the
  forks the chart versions both sides, tags, the compare, 90 days of commits, our PRs. Verified on all three projects;
  Codex reproduced every count independently. Reports: `docs/upstream/releases/cilium-v1.20.2.md`,
  `hubble-observer-2.7.0.md` — **upstream released the fork's five PRs as 2.7.0 on 09-15**, then removed `containerName`,
  deleted the second-release example, and left cf2cnp at `*` = 0.4.0 / binary 0.3.1; the fork is 29 ahead, 0 behind;
  #16 open. Demo 25 Part 10c; `docs/upstream/README.md` §5.
- **The upgrade** (PR #34, on "then proceed"): poc1 first. **Gotcha #117** on the first attempt — `--reuse-values` with
  `--version 1.20.2`: "deployed", revision 6, "successfully rolled out" in 14 s, agents still on 1.20.1; `helm get values
  --all` carried `image.tag: v1.20.1` from the old chart's defaults (Helm 4.3.0 `reuseValues`:
  `CoalesceValues(current.Chart, current.Config)`, read in the source). `--reset-then-reuse-values`: revision 7, agents
  at +29 s, everything at +100 s, user values byte-identical at 5 and 7. The Gateway probed every second: **121 failed
  probes in the 132 s between +6 s and +138 s** — the Envoy DaemonSet rolls when the release bumps its image (three
  times in 1.20.2), unlike #116's agent-only ~45 s; the four L2 leases moved to the worker. Demo 37's `check.sh`
  identical before/after apart from pod names and lease holders; six listeners `Programmed=True` (no 1.20.1 record of
  the per-listener condition exists — `check.sh` now prints it). poc2: 35 s, no Gateway. Mesh connected both ways;
  poc1 214.5 / poc2 39.6 flows/s in Grafana; the observer re-deployed on the 1.20.2 CLI (`hubble v1.20.2 … go1.26.8`).
  Pins: `lab-stack.sh`, `lab-preflight.sh`, `lab-up.sh`, `bootstrap/versions.env` (the bootstrap's own check would
  have failed CI at step one without it), the observer's digest, `apply-poc2.sh`, `mtls-check.sh`, the README.
- **Review** (`docs/REVIEW_RELEASE_NOTES.md`): Codex refuted "every one a backport" (34 of 138 name one PR) and
  "2 min 12 s off the air" (a span, not a continuous outage); Grok refuted the report's outcome vocabulary (the skill now
  names six) and one sentence judging the maintainer; the `sed` delimiter in `check.sh` replaced by `printf`. Merged:
  #33. The CI proof for #34: `lab-observability` on the branch with the connectivity test (run 35283148292) — every
  step through the captures green on 1.20.2; the connectivity test still running at 00:35Z.

## Part 10 — "Go ahead": the fork, the upstream posts, the dashboard made to mean something, the Grafana tutorial (2026-09-17 18:30 → 01:00)

- **The fork** (ephico2real2/hubble-observer): #1 merged (the flow table's cluster columns), #2 the cf2cnp subchart
  0.7.0 → 0.9.0 (tested locally first — the deployment's args carry `--log-format json`, the pod's first line is JSON,
  `/health` 200; the cluster columns render, `poc1` on every row), #3 the dashboard redesign, #4 dated backups
  (`dashboard/backup/…2026-09-17.before-meaning-and-colours.json`, `…2026-09-15.upstream-2.7.0.json`; copies under
  `demos/25-hubble-observer-loki/dashboard-backup/`).
- **Upstream, on the operator's word:** a status comment on onzack/hubble-observer#16 (edited once — "rebased" →
  "merges cleanly", the truthful word); **cilium/cilium#48811** (the Ubuntu base's `pebble` is the last Go 1.26.5 binary
  in `cilium:v1.20.2`; bump the digest or drop the binary — the bug template's fields, the commands, the AI declaration);
  **cilium/cilium#48812** (`destination_workload` empty for Envoy-reported L7 flows with a remote backend — re-checked
  on 1.20.2 first: both `shop` backends on the control plane, the worker's Envoy reports `destination_workload=""`).
  Candidate A of the scan report was **not** posted: Renovate had opened cilium/cilium#48808 (grpc 1.83.2 + x/crypto
  0.56.0 for `v1.20`) twelve minutes before the check — the report's rule ("re-run §7; if it moved, the candidate is
  closed") did its job.
- **"Flows per Destination" had never had data; "Flows per Source Namespace" coloured different namespaces alike.**
  Research first (`docs/OBSERVER-DASHBOARD-PANELS.md`): every field from `flow.proto` at v1.20.2, the observer's command
  (`--verdict DROPPED` — every panel counts drops), Grafana's guidance, and the colours read from the DOM — instant
  query + *All values*: 28 %/28 % both rgb(87,148,242), 33/33/33 all rgb(115,191,105); the three pies in the range +
  *Calculate* shape coloured per series. The test that fills the empty panel: demo 31's `pos` (an L7 DNS rule,
  `toFQDNs` for `example.com:443` only) → `wget https://example.org` → twelve `DROPPED POLICY_DENIED pos → example.org:443`
  with `destination_names`; the panel filled in fifteen seconds. Found in the data on the way: eleven
  `STALE_OR_UNROUTABLE_IP` drops at 22:34–22:35Z were poc2's edge Prometheus scraping `10.20.0.109:9962` — the
  clustermesh-apiserver pod the 1.20.2 rollout replaced.
- **The redesign** (`demos/25-hubble-observer-loki/dashboard-design.py`, Cursor from two briefs; fork #3; lab PR #35):
  caption strips under every Statistics panel, the two rankings as sorted `topk(10)` bar gauges in one colour, fixed
  colours per meaning, hover descriptions, the logs panel titled. Two first-pass faults the render caught: the caption's
  HTML marker sharing the text's line rendered raw markdown (CommonMark HTML block → the marker on its own line); a bar
  gauge on a range query did not sort (one frame per series → instant + *All values* + `sortBy "Value #A"`). Read back:
  8 captions as markdown, bars 2.67K → 1.66K. Review (`docs/REVIEW_OBSERVER_DASHBOARD.md`): Codex found two
  `flow.proto` quotes altered and three "Now" cells quoting captions the file did not carry — fixed; Grok's doubt about
  `POLICY_DENY` refuted by `flow.proto:495` (`POLICY_DENY = 181`); the mechanism sentences relabelled as readings the
  fix confirmed.
- **Demo 38, the Grafana tutorial** (PR #36): six dashboards from node_exporter and kube-state-metrics up to Hubble,
  generated (`build.py`), provisioned, proven (`check.sh`: 30 panels, 0 NO DATA), captured (31 captions read back). The
  lessons were measured before they were written: the **by-name palette** gives one colour to every series in a pie, a
  stat and a bar gauge (a 25-slice pie all cyan; 2 distinct colours in 50 bar swatches) and a stable colour per name
  only on a time series (17 distinct for 25 names) — grafana#73275; so the README's first draft of §3, which promised
  by-name for pies, was rewritten to the measurement, and `tut-3` shows all four cases side by side on five namespaces.
  Every reference URL resolved (200); the videos are Grafana Labs' beginners series.
- **Queued by the operator, not started:** fork cilium/cilium, find the code path behind #48812, fix it, build the
  image on the M5, prove it as a demo — after the tutorial.

## Part 11 — the fix built and proven; the rules of the night (2026-09-18 01:00 → 05:10)

- **Three operator rules, in their words, now in memory and the skill:** *"Don't merge automatically — remember you
  need to approve it"* (every PR since waits: #34, #39, #40, group-sync-dashboard #176 — the review skill with OB1);
  *"before the issue is updated, use Fable 5.1 for an adversarial review and share the response in docs/upstream first"*;
  *"call Anthropic Fable 5.1 OB1"* — the Agent tool with `model: fable`, the same brief and read-only rules as Codex
  and Grok, not Cursor's Fable (whose usage cap refused a run that night). *"Deploy the same Cilium version into both
  poc1 and poc2."* *"Keep the patch — we are engineers."*
- **OB1's first review** (PR #39, the regression work) predicted from the code that the first CI run "cannot go green"
  and named why — the runner did not trust the lab's root (`LAB_TRUST_ROOT` unset), could not resolve the names (no
  `lab-route.sh`), row 4 probed names the trimmed lab never deploys, the connectivity test's success regex could never
  match the CLI's real line, a query error counted as data. Run 1 failed exactly so (7 PASS, 6 FAIL); run 2 after the
  fixes: 13 PASS, 0 FAIL on a fresh runner. Runs 3–4: the observer dashboard's capture — "not timing after all", the
  trimmed stack had skipped `tempo` + `collectors`, and the OTel collector is the Loki shipper (lab-stack.sh's own table);
  run 4 green end to end (`docs/REVIEW_REGRESSION.md`, `docs/regression/README.md`).
- **"Test the cilium here and rebuild and redeploy the images here"** — demo 39. Fork `ephico2real2/cilium`, branch
  `hubble/remote-workload-via-cep` on v1.20.2: the workload on `CiliumEndpoint.status.workloads` (CRD 1.33.12 → 1.33.13)
  → the slim type → `ipcache.K8sMetadata` → Hubble (commit 1, Cursor from a brief; the generators in the builder
  container). Built on the M5 (`make dev-docker-image`, 86 s warm), loaded into poc1, the CRD applied **and labelled**
  first (both reviewers: a field the schema does not know is pruned silently — the first deploy would have measured
  nothing), the agents rolled in 15 s. **Measured: L3/L4 flows from the worker named the control-plane pod's workload;
  the Envoy-reported Gateway flow still `destination_workload=""`** — Hubble has two parsers, and the L7 one
  (`pkg/hubble/parser/seven/parser.go`) resolves endpoints on its own. OB1, reviewing commit 1 in the same hour,
  found the same line ("commit 1 alone would have measured nothing on the L7 dashboard"). Commit 2 fixed it; commit 3
  closed Codex's edge (a bare local pod must clear a stale value). Both clusters on `1d3a02ab`: the worker's agent
  reports `destination_workload="shop"` for Gateway flows to control-plane backends, 40/40 both teams; Cilium's own
  *L7 by Workload* dashboard fills for the remote backend where it was "No data" (the highlighted capture — square
  boxes, one colour each, the operator's spec). `docs/REVIEW_CILIUM_FIX.md`.
- **Upstream, on the operator's word, with the gate applied:** OB1 and Codex found cilium/cilium#48563 — an open
  draft doing the same with CES and the kvstore path (its predecessor #36011 died in 2025 as CEP-only) — so no
  competing PR; the review comment bringing what the draft lacks (the CRD schema-version bump; the L7/Gateway
  reproduction, before/after pictures, how it was tested, the operator named as the one who directed the work and
  designed the test cases) drafted under `docs/upstream/drafts/`, read by the operator, posted: #48563
  issuecomment-5725111947; the CI follow-up 5725439704. Earlier that night, before the gate: the #25676 comment (after
  a duplicate #48812, closed) and #48811.
- **The lab keeps the patch:** `versions.env` pins `CILIUM_IMAGE=ghcr.io/ephico2real2/cilium-dev:1.20.2-remote-workload-1d3a02ab`
  with the fork's CRD URL and schema version; `lab-up.sh` installs it and applies the CRD in the safe order; the
  regression check expects it (14 PASS). The image pushed to the operator's ghcr (made public), **rebuilt for
  `linux/amd64,linux/arm64`** after the first CI runs on it died at `Init:ImagePullBackOff` (arm64-only), and the
  `lab-regression` Action runs demo 39's `check.sh` when the build is pinned: run 35307892865 — a fresh amd64 runner,
  client on one node, backend on the other, `destination_workload="shop"` — green end to end.
- **Measured numbers to keep:** the 1.20.2 rollout darkens the Gateway ~2 min when the Envoy image changes (121 failed
  probes in 132 s; #116's agent-only ~45 s); `helm upgrade --reuse-values` across a chart version keeps the old image
  (#117); the by-name palette colours every slice of a pie alike on Grafana 13.2.1 (demo 38); an instant query with
  *All values* colours equal counts alike (the observer dashboard's defect); a CiliumEndpoint status field the CRD
  does not know is pruned with no error.
- **"You can merge the prs" (2026-09-18 ~05:40 UTC), the one-time word for the PRs then open:** #40 (demo 39) and #39
  (the regression testing) merged, group-sync-dashboard #176 (the review skill with OB1) merged; #34 (the 1.20.2 pins)
  had conflicts with the merged main — rebased with the two resolutions (README line 3 and the docs row: main's text
  with 1.20.2 and 117 traps; `lab-up.sh`: main's `CILIUM_IMAGE`/CRD block with the chart pin at 1.20.2), the
  `lab-regression` Action run 35311034810 green on chart 1.20.2 + the pinned build (a combination CI had not run),
  merged as e28b63d. The no-automatic-merges rule resumes for everything after this line.

## Part 12 — the merges, the port to main and what the reviewers found, Tetragon, enhancement 002 begins (2026-09-18 05:40 → 09:00)

- **"You can merge the prs"** — #40, #39, gsd #176 merged; #34 had conflicts with the merged main (README line 3 and the
  docs row; `lab-up.sh`'s `CILIUM_IMAGE` block against the chart pin) — rebased, resolved on main's text with 1.20.2 /
  117 traps, the `lab-regression` Action green on chart 1.20.2 + the pinned build (run 35311034810), merged `e28b63d`;
  the session log Parts 9–11 as #41. The no-automatic-merges rule resumed at 05:45.
- **"Did you open the pr upstream cilium" — no; "I sign off after ob1".** The three v1.20.2 commits ported to
  cilium/cilium `main` (`cccadb0e70`): six conflicts, all main's pod-UID work landing under ours (`K8sMetadata.PodUID`,
  the ID-match guard in `updateEndpointFromLocal`, `TransformToCiliumEndpoint` without the tombstone arm,
  `DeleteOnMetadataMatch` with a `uid`); `--ours` on a conflicted file drops its non-conflicting hunks too (the
  `Workloads` field and the import came back by hand); `CustomResourceDefinitionSchemaVersion` 1.34.4 → 1.34.5;
  squashed to two commits with upstream-shaped messages; `make manifests` and `make generate-k8s-api` reproduce the
  committed files byte for byte. Fork branch `hubble/remote-workload-main`.
- **Three reviewers, one brief (eleven claims):** the code CONFIRMED everywhere, with two corrections to what I had
  claimed — my "ok pkg/endpoint" was three SKIPs (`INTEGRATION_TESTS`); OB1 stood up an etcd and ran the writer test:
  PASS on the branch, FAIL reverted. **The PR text REFUTED ×3:** it said #48563 lacks the L7 half — #48563 has carried
  it since 2026-09-08, and our own comment there says so; `metrics.rst` named schema 1.33.13 (the v1.20 number — a
  1.34.4 cluster is "later" and still prunes); the release note prescribed "run the operator before the agents", an
  order the docs do not have; the declaration claimed a human pass that had not happened. Applied: the doc version
  with the pruning caveat and an upgrade note, `TestDecodeL7WorkloadsReplacementEndpointKeepsIPCacheWorkload`,
  `TestUpsertWorkloadOnlyChangeReachesMetadata` (head `63650a0445`), the draft rewritten as a fact sheet with the two
  routes (feed #48563 first; open ours as the smaller alternative). Rejected with reasons: Codex's synchronizer retry
  (real — `lastMdl = mdl` after a successful patch — but pre-existing for every CEP status field; `serviceAccount`
  shipped the same way), `SetPod` on pod updates, and a genuine upstream bug in `pkg/k8s/utils/workload.go` (a label
  deleted from the cached Pod's shared map) — recorded as its own candidate. `docs/REVIEW_CILIUM_UPSTREAM_PR.md`.
- **The clause we had missed:** `cilium/community/AI-POLICY.md` *Unacceptable Use* — no communicating in Cilium
  spaces with content "substantially written using Generative AI tools … Slack or GitHub". The three posts of the
  night before were AI-drafted and posted verbatim on the operator's word. From here a draft is a fact sheet and the
  operator writes the words; §2a of `docs/upstream/README.md` and the memory say so (PR #45).
- **Enhancement 002, revision 4** (PR #43, issue #42): the lab re-measured — demos renumbered 40–45; poc2 already had
  the Gateway API, L2, its pools and metrics-server; cf2cnp 0.9.0 has `fromCIDR`; poc1 is 1 CP + 1 worker; revision
  3's addresses did not sit in the design's /26 blocks (`.160`, `.170–.173` in poc2's service range, `.245`/`.243` in
  poc1's Gateway-only pool) — redone: VIP `.16`, shop gateways `.242`/`.177`, egress IPs `.40–.43` node-held.
  Resources: the Docker VM at 17.0 of 24 GiB, ~1.1 cores; the platform adds ≈ 1–2 GiB; no resize.
- **"Tetragon must be crazy":** my first reading ("a warning loop since 09-15") was wrong — Prometheus had the pod at
  0.01 cores until 06:12 UTC. At 06:12:58 the Cilium builder's `go test` started on the same Docker VM; at 06:13:21–22
  **all four Tetragon agents, both clusters, were OOM-killed** at the chart's 512 Mi (`dmesg` `CONSTRAINT_MEMCG`,
  anon-rss 425–475 MiB) — they share the kernel, and Tetragon's exec sensor is on the kernel; the poc2-worker agent's
  own counters afterwards: 3071 `go vet` + 1716 `compile` execs from the builder. After the restart the policy filter's
  cgroup lookup fell through to `filepath.WalkDir` over the VM's whole cgroup tree (`pkg/cgroups/fsscan`,
  `pkg/policyfilter/state.go` v1.7.1) — the 1.6–4.2 cores and the `failed to find cgroup id` line. Gotcha #118 (PR
  #44); `values-tetragon-ci.yaml` 512Mi → 1Gi rolled on both clusters; **the killing test rerun cold** (the 2.0 GB
  build cache emptied): peak RSS 524 Mi — above the old limit — 0 restarts, `dmesg` count unchanged; the regression
  check 14 PASS. The rule: no build containers on the VM while a demo measures.
- **Demo 40 — phase 0 of 002** (branch `demo-40-shop-mesh-phase0`, Cursor from a 1,800-word brief): measured first
  that a Gateway with two `spec.addresses` gets both IPs on one Service, and that an L2 policy selects Services, not
  IPs — so the VIP lives on its own `shop-vip-gw` per cluster, both `kind-l2-announce` policies exclude it, and
  `cilium/l2-shop-vip-announce.yaml` is applied in exactly one cluster (`scripts/vip-takeover.sh`, delete-other-first;
  measured: the lease moved to `poc2-worker` and back; dying leases linger ~15 s with an empty holder). The shared pool
  `.16–.31` in both clusters; `shop-tls` from the common root (`clustermesh-root-ca`, the same fingerprint in both) with
  the three SANs — a wildcard would not cover the two-label names; four Gateways Programmed, answering 404 until demo
  41; `shopapi` (Go, pgx 5.11, distroless nonroot) loaded on all four nodes; `shopctl` in Go and Python; `check.sh` 21
  PASS on both clusters. Cursor's measured differences from the brief: the L2 selector change moved no existing lease;
  the Mac never ARPs for the VIP (the host route's next hop is the VM). Reviewed by OB1 + Codex + Grok (`docs/REVIEW_DEMO40.md`): the wire confirmed — one ARP responder for the VIP
  (`arping` from the bridge), poc1's leaf on `.16`, the lease flip in ~40 ms; eleven findings applied from the
  reviewers' snippets — the worst: `check.sh` PASSing an unreachable door (`000000`); `vip-takeover.sh` with no way
  through when the other cluster's API is down (`--force`, UNKNOWN); `shopapi` opening a pool per request with no
  connect timeout; the clients disagreeing on `--duration 3` vs `3s`; `cleanup.sh` leaving the Secret; `record.sh`'s
  deliberate return-0 contract kept, with a `RECORD_STRICT=1` opt-in for `apply.sh`. After the fixes: 21 PASS on both
  clusters, regression 14 PASS. The operator, twice now: *"dont poll the back job — set up a watcher"* — in memory.
