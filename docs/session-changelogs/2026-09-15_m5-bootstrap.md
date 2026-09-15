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
