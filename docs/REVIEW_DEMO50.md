# Review — enhancement 007 phase 0 and demo 50, the vanilla lab's clusters (2026-09-18)

Three reviewers on one brief (`scratchpad/review_brief_demo50.md`, eight claims: the guide's idempotence and
Linux-safety; the three-command Envoy Gateway install; the network and the reservation trick; stock networking; the
lab root; `check.sh`; the docs; what must not have moved): **OB3** — the OB1/OB2 reviewer's role on **Opus 5**, sourced
from the shared skill (`.claude/agents/ob3.md`; the Fable quota was out for the third demo running) — 66 tool uses,
18 min, depth chosen per claim and named: deep on C1, C2-A/C, C5, C6, C8 (a harness with a fake `kubectl` on PATH,
the vendor page fetched, the CRD chart rendered, kind's provider source read), medium on C2-B, C3, C4 (one live
drive each), grep on C7's counts; **Codex** (gpt-5.6-sol xhigh — sandbox without cluster, Docker or file-write access;
live verdicts PLAUSIBLE from the transcript, code findings measured; its report reached the record only as the
hand-back message — the sandbox could not write the file); **Grok** (Cursor `cursor-grok-4.6-high-fast`). Every
accepted finding was re-read against the code by the orchestrator before Cursor applied it from the reviewer's
snippet; the behavioural ones were re-run and the tests checked in under `tests/`.

Under review: branch `eg-phase0` at `575021d` (phase 0 record, plan rev 2, gotcha #119, demo 50, OB3) — PR #62.

## What held on the live clusters (re-measured by OB3 and the orchestrator)

| Claim | Evidence |
|---|---|
| the reservation trick (R1) | `kind-eg` `172.19.0.0/16`, ip-range `/17`, gateway `.1`, IPv6 `fc00:f853:ccd:e794::/64` (its block has no IPRange key — the `invalid Prefix` quirk confirmed); nodes `.2/.3/.4/.5`, nothing in `.255.0/24`; CIDRs `10.50/10.51`, `10.60/10.61` disjoint from poc1–4 and from `kind`; both kubeadm patch versions kept because kind renders v1beta4 and ignores the other silently |
| stock networking (R2) | kindnet and kube-proxy `2/2`, `mode: iptables` (ConfigMap line 55), 0 Cilium DaemonSets, 0 Cilium CRDs — both clusters |
| the CRD sets (R3, D10) | 10 `gateway.networking.k8s.io` CRDs, every one `channel: standard`, `bundle-version: v1.6.2`; 8 `gateway.envoyproxy.io`; 0 experimental; `helm list` = `eg` + `cert-manager`; GatewayClass `eg` Accepted with `gateway.envoyproxy.io/gatewayclass-controller`; envoy-gateway Available. The vendor page, fetched: *"We're using `helm template` piped into `kubectl apply` instead of `helm install` due to a known Helm limitation (helm/helm#12277) related to large CRDs"* |
| one root (D8) | the same sha256 `6A:37:32:53…67:16` **and the same `tls.key` sha256** on both clusters — a copy, not a re-issue; ClusterIssuer Ready ("Signing CA verified"); `.tmp/` gitignored; no `.crt` tracked |
| nothing else moved (C8) | poc nodes `Exited (137)` with `RestartPolicy=no`; the `kind` network unchanged; `lab-up.sh`, `versions.env`, `lab-regression.sh`, the workflow: empty diff against `origin/main`; kind v0.33.0 `provider.go:71-76` reads `KIND_EXPERIMENTAL_DOCKER_NETWORK` with no OS branch |

## Findings, accepted and applied

| # | Finding | From | Fix, measured |
|---|---|---|---|
| A1 | **`first=$1`: `scripts/eg-up.sh eg2` alone minted a second root in eg2 and exported it over `.tmp/eg-root-ca.crt`** — the guide kept one root only because eg1 happened to go first (OB3's most important finding) | OB3 F1 | `ROOT_HOME=eg1` always mints; eg1 processed first when present; other clusters copy eg1's Secret or `die` ("run eg-up.sh eg1 first"); `$first` gone; the copy via `apply --server-side --force-conflicts` (OB3 F6). `tests/eg-up-root-home.sh`: FAIL before ("eg2 minted a root"), PASS after; the live re-run kept `6A:37…` on both |
| A2 | `helm repo add/update` bypassed `record.sh` and masked failure (`\|\| true`) | Codex F1, OB3 C1 | both through `rec helm_r …`, `--force-update`, fatal on failure |
| A3 | `eg-up.sh` attempted `helm upgrade --install eg-crds` first and failed deterministically (the release Secret > 1 MiB) before falling back | OB3 F5, Grok, Codex; the operator: *"I don't mind the manual helm template approach"* | straight to the vendor-prescribed `helm template … \| kubectl apply --server-side -f -`, the vendor's sentence quoted in the script and the record; the 1 MiB measurement kept as the why |
| A4 | the "no Cilium" check row **PASSed when `kubectl` failed** (`grep -c` on nothing = 0 — demo 40's class) | Codex F2, OB3 C6a, Grok | the two queries captured first; a failed query → FAIL; DaemonSets and CRDs both counted. `tests/check50-cilium-row.sh`: "a dead kubectl produced a PASS row" before, "dead kubectl → FAIL row" after |
| A5 | **the orchestrator's own imprecision:** the record said the CRD chart's Gateway API set renders "13 × experimental, 2 × standard CRDs" | OB3 F4 | rendered: **13 CRDs, all experimental, at v1.6.1** (the 10 core kinds + `xbackends`, `xbackendtrafficpolicies`, `xmeshes` of `gateway.networking.x-k8s.io`), plus a `ValidatingAdmissionPolicy` and its Binding labelled standard — not CRDs. Record, RECAP and GUIDE corrected; `tests/crd-chart-render.sh` prints the counts |
| A6 | the cert-manager row's RULE named no requirement | Grok F1, Codex F3, OB3 C6b | `D8 — cert-manager v1.21.1 Available for the lab root` |
| A7 | the README's `check.sh` block was a paraphrase typeset as output — eight rows not in the transcript | Grok F2, OB3 F3 | re-recorded after A4 and quoted verbatim; `tests/readme50-verbatim.py` checks every quoted row against the transcript |
| A8 | the plan still said `docs/eg-root-ca.crt` (three places) and `versions.env` (two) for this lab; the RECAP's goal heading off the skill's shape; its review paragraph said "not run" | Codex F4, Grok, OB3 F7 | corrected; the RECAP names the three reviewers and the owed second reading |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| `scripts/lab-regression.sh` "was changed on this branch" (C8) | Codex F5 | an artefact of a stale local `main` (11 commits behind); against `origin/main` the file's diff is 0 lines — OB3 noted the same stale ref |
| Strip `last-applied-configuration` from the copied Secret on eg2 | OB3 F6, second half | the first copy was client-side and left the annotation (1971 → 1954 bytes after the server-side re-apply); a fresh cluster never gets it; not worth an `annotate` step in the guide |

After the fixes: `eg-up.sh` re-run idempotent in 24 s (both clusters "exists, kept", the root copied from eg1, no
`kind create`, no `helm install eg-crds`); `check.sh` **27 PASS, 0 FAIL** re-recorded; one root, `6A:37:32:53…67:16`
on both clusters and in `.tmp/eg-root-ca.crt`; every `.md` 0 issues under bash. Reports: `scratchpad/review_ob3_demo50.txt`,
`scratchpad/review_grok_demo50.txt`; Codex's in its hand-back message. **Owed: OB1/OB2's second reading of OB3's pass**
(the skill's rule), and OB1's passes on demos 41 and 53.
