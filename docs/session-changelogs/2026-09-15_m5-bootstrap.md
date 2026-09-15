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
