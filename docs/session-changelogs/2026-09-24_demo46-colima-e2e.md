# Session change log — cilium-implementation-poc, 2026-09-24

Demo 46 stops describing a fabric with nothing peered and records its own end-to-end run: a kind cluster on
the node LAN, kube-vip dialling into the leaves, and a packet crossing to the VIP the cluster announces. Times
are git author times in America/Chicago; every number below is one this session ran a command for.

Outcome in one line: **the Colima fabric proves the data path on this machine, and three review passes each
caught a claim the previous pass and I had both missed.**

| | Before the session | After |
|---|---|---|
| Demo 46's pages | described a fabric alone — `external=2`, "no members", "next phase" in ten places | the recorded run: sessions Established, the VIP answered, the leaves signing |
| `docs/EG-VS-CILIUM.md` | absent; three issues waited on it | written, 122 lines, sourced |
| The data path | `scripts/fabric-servers-join.sh` and `scripts/fabric-traffic.sh` existed, never recorded | both recorded in `demos/46-bgp-fabric-colima/output/transcript.txt` |
| `tests/demo46-colima-claims.py` | REQUIRED the phrase "next phase" — it enforced the stale world | that requirement removed, six assertions added |
| Demo 46's gate sweep | 27 gates | 31 gates, 0 FAIL |

---

## Part 1 — the end-to-end run and the comparison (19:33) — commit `72211db`

- `scripts/demo46-colima-e2e.sh` runs the eight steps on this MacBook: the Colima VM, the four routers, the node
  LAN, a kind cluster on it, the leaves attached after the recorded apply, the servers joining, traffic, and
  `demos/46-bgp-fabric-colima/check.sh` through `scripts/record.sh` with `RECORD_STRICT=1`.
- **Measured:** the overlay attaches after apply because `--no-recreate` cannot add a network to a running
  container, with `docker network connect --ip` as the fallback; compose never removes an *extra* network
  (`mustRecreate`, in compose v5.5.1's reconcile source) — the earlier "leaf1 came back on mgmt alone" was
  the overlay having never attached, not a removal.
- `docs/EG-VS-CILIUM.md` written, the artefact three tracker issues were waiting on, with
  `tests/docs-eg-vs-cilium-sources.sh` gating its sources.

## Part 2 — OB1-lite's pass (19:52) — commit `5604851`

Three findings, each verified before it was applied:

- **A regression this session introduced:** routing `demos/46-bgp-fabric-colima/check.sh` through `scripts/record.sh` swallowed its exit
  code. `scripts/record.sh` exits 0 unless `RECORD_STRICT=1` — by design, because demos here prove things by failing.
  Measured: rc=0 with a check that exits 1.
- **An invented number:** "kube-vip elects in well under a second" appears nowhere in the tree; the RECAP's own
  figures are 10.837 s and 10.909 s.
- **A mechanism backwards:** the commit message's compose explanation contradicted itself two paragraphs apart.

## Part 3 — OB2's pass (20:31) — commit `0648a03`

- **The same swallowed-failure bug six lines away:** `scripts/fabric-traffic.sh`'s six recorded replies read
  nothing. The fix I had written was narrower than the defect I had proved.
- **A gate that could false-pass:** an `rc=0` after step 6 satisfied the line-level test; rewritten to run the
  script. `tests/fabric-traffic-recorded-replies.sh` and `tests/demo46-colima-e2e-check-rc.sh` are the result.
- **An inferred measurement:** the MetalLB cell borrowed kube-vip's result — `spec.addresses` alone was never
  tried on MetalLB.

## Part 4 — the re-record (20:56) — commit `4aa293b`

- The run recorded: `SERVERS sessions 4/4 Established`, `client0 reaches 10.198.0.46` answered by the probe pod,
  `demo 46 traffic: 0 FAIL`, `demo 46-colima check: 0 FAIL`.
- **Found on the way:** `busybox httpd` is not in Alpine's applet set (`busybox --list | grep -c httpd` → 0 on
  alpine:3.22), so the probe became `traefik/whoami:v1.11`; the Service stayed `<pending>` until the `kubevip`
  pool ConfigMap existed; and `client0` scored 0/20 until the node gained `10.200.0.0/16` via the leaf on the
  node LAN — Docker does not forward between two bridges.

## Part 5 — OB1's pass, and the gate that enforced the error (21:25) — commit `522cede`

- **RECAP steps 8 and 9 still cited demo 55** — "not yet recorded on this fabric", quoting run 35953641113 —
  while the transcript beside them held every number they waited on. I had re-recorded the timings and never
  read the two paragraphs that were the reason for running the lab.
- **Ten further places still described a cluster-less fabric:** `external=2` ×3, "no members" ×2, "next phase"
  ×2, `Displayed 5 routes and 5 total paths`, `time 2073ms`. GUIDE's tables came from an apply three runs old,
  because the verbatim gate read README only.
- **The gate did not merely miss it — it required the error.** `tests/demo46-colima-claims.py` asserted that
  "next phase" must appear, so a page overtaken by its own evidence passed *because* it still said the cluster
  was coming later. Inverted: the results must be present, the stale phrases must not, and every GUIDE ```text
  line must be in the last apply. **Measured: 24 CLAIM FAIL lines against the previous pages; 31 gates, 0 FAIL
  against the fixed ones.**
- **A correction to my own commit message:** it quoted `demo 46 traffic: 0 FAIL`, `client0 reaches 10.198.0.46`
  and "the leaves are signing" as evidence. Those three lines are in no transcript — they are `echo`, not `rec`,
  so they reached the terminal and nowhere else. Presenting terminal output as recorded evidence, in a commit
  about recording evidence.

## Part 6 — the machine, at the operator's instruction (21:30 → 21:50) — no commit

- Colima profile `bgp-fabric` **Stopped**; sixteen containers stopped first, the three mongod exiting 0. Both
  kind clusters (`eg-poc1-colima`, `eg-poc2-colima`) stopped, not deleted. Docker Desktop was already down.
- On CRC, the `mongodb-poc` search tier taken to zero pods. **Measured:** the MongoDBSearch CRD gives
  `clusters[].replicas` a `minimum: 0` and names 0 as the offline switch, but
  `loadBalancer.managed.replicas` a `minimum: 1` — the API server refused 0 — and the Envoy Deployment is
  controller-owned, so a direct scale was reverted to 2 before its pods terminated. The operator's sequencing
  fixed it: scale the reconciler to 0 first.
- **Measured on the host:** 64 GiB, 150 MiB truly free, the compressor holding 54.4 GiB of logical data in
  23.6 GiB of RAM, swap 7351 of 8192 MiB after 72 days of uptime. `purge` needs root and does not reduce swap;
  only a reboot does.
