# Review — demo 40, the shop platform on the mesh, phase 0 (2026-09-18)

Three reviewers, one brief (`scratchpad/review_brief_demo40.md`: eleven claims — the pool and L2 selectors, one
announcer for the VIP, the takeover script, the Gateways and the certificate, `apply.sh`, `shopapi`, the two clients,
`check.sh`, `hosts-entries`/`cleanup`, the docs, CI), read-only on the live clusters: **OB1** (Anthropic Fable 5.1,
`Agent` `model: fable`, 43 tool uses, 21 min — `arping` from the kind bridge, the leaf fingerprints per cluster, the agent
logs of the lease flip, shim tests with a fake `kubectl`, a silent TCP server against `shopapi`), **Codex** (gpt-5.6-sol
xhigh — its sandbox had no cluster, Docker or socket access, so its live claims rest on the committed transcript; its
code findings were measured), **Grok** (Cursor `cursor-grok-4.6-high-fast`). Every accepted finding was re-read against
the source by the orchestrator before Cursor applied it from the reviewer's own snippet; the ones that changed
behaviour were re-measured after.

## What all three confirmed on the wire

| Claim | Evidence |
|---|---|
| C1 the selectors: `NotIn [shop-vip-gw]` still selects every Service without the label; no existing address lost its announcer | every pre-existing l2announce lease has a holder on both clusters (routes-gw .240, sw-gateway .241, team-b-gw .243, hubble-ui .201 — no label; rebel-base-lb .136 — no label); the Kubernetes label-selector doc quoted |
| C2 one announcer for the VIP | OB1: `arping -c 3 -I eth0 172.18.255.16` from a container on the `kind` bridge → three unicast replies from `2a:41:4a:7f:cf:12` = poc1-control-plane's `eth0`; controls .242 → poc1-cp, .177 → poc2-cp. The leaf fingerprints differ per cluster (.16 and .242 share poc1's `43:21:FC:A4…`, .177 is poc2's `C8:9E:AB:79…`) so `curl` to .16 provably got poc1's leaf. Agent logs: poc1's two nodes "Job stopped" at 12:47:23.527/.530, poc2-worker "Successfully acquired lease" at .569; back in ~40 ms |
| C4 the manifests match the live objects | `spec.addresses` .242/.16 and .177/.16, one `status.addresses` each, Programmed=True, the three hostnames with `shop-tls`, `allowedRoutes` by label, `http:80` present (404, no redirect yet). A `*.shop.poc.local` certificate measured with `openssl verify -verify_hostname`: OK for `api.shop.poc.local`, **fails** for the two-label names (RFC 6125 §6.4.3) — the three SANs are required |
| C8 `check.sh` | 21 rows, exit = FAIL count, the lease row on a non-empty holder in exactly one context (live: `poc1 holder=…`) |
| C11 CI | `lab-up.sh:222` applies the two per-cluster pool files; the `NotIn` is inert without `shop-vip-gw`; the regression workflow greps nothing these files changed; demo 40 is not in it (phase 1 adds the row) |

## Findings, accepted and applied

| # | Finding | From | Fix, measured |
|---|---|---|---|
| A1 | `check.sh`: `curl … \|\| echo 000` yields `000000` on failure and the test rejected only `000` — **an unreachable door PASSed**; the door rule said "404 is PASS" but the code passed any non-000; the image rows vanished when `kind get nodes` failed | Codex (shim: 17 rows, three `PASS http_code=000000`), OB1 F7, Grok | an `http_code()` helper, PASS only on 404, a fixed node list; shim after: 21 rows, three door FAILs, no `000000` |
| A2 | `vip-takeover.sh`: the DR flip deletes the OTHER cluster's policy first — with that API down it exits 1 before applying; `--status` reported the dead cluster as "absent / lease: none" | OB1 F1 (shim `DOWN_CTX`: 3 FAIL) | `--force` (fail-closed stays the default with a warning), `reachable()` via `get --raw /readyz`, "API unreachable — announcer state UNKNOWN"; Grok's `holder_of()` trim; shim after: 5 PASS; the normal flip's kubectl sequence byte-identical |
| A3 | `apply.sh`: VIP_BY read lease existence (BOTH during the ~15 s dying lease); poc1 hard-coded as the VIP home; failed waits did not fail the script because `record.sh` returns 0 | OB1 F5, Grok, Codex C5 | holder-based `final_table` through `record.sh`; `VIP_HOME`; **`RECORD_STRICT=1` opt-in in `record.sh`** (default unchanged — its contract is that demos may record expected failures under `set -e`); `RECORD_STRICT=1 … exit 7` → 7, default → 0 |
| A4 | `shopapi`: `sql.Open` per request, no connect timeout (a TCP listener that accepts and never speaks held `/ready` for the full 2 s), 404s without the identity headers | OB1 F2, Codex fix 3, Grok | one pool (`pgx.ParseConfig` + `ConnectTimeout` 1 s + `stdlib.OpenDB`, `SetMaxOpenConns 8`), a middleware for the headers, `ReadHeaderTimeout` 5 s; `TestReadyConnectTimeoutBoundsSilentServer` 2.002 s → ≈1.0 s; image rebuilt `c32cc3df…` → `0fe50505…` on all four nodes |
| A5 | the clients: Go wanted `--duration 3s`, Python `--duration 3` — one runbook line could not run on both; the percentile methods differed ((5,9,9,10) vs (5.5,9.55,9.91,10.0) on 1..10) | OB1 F3, Codex fix 4, Grok | both accept a bare number or Go units; Python moves to nearest-rank; contract tests on both; `load --rate 5 --duration 2 --timeout 500ms` runs identically. The last second not sleeping is kept (symmetric) and documented |
| A6 | `cleanup.sh` left `Secret/shop-tls` (cert-manager without `--enable-certificate-owner-ref`; ownerReferences empty on both, measured) | all three | the delete added; shim 0 → 2 |
| A7 | `shop-vip-gw` matched TWO pools (`gateway-pool` `Exists` and the shared pool) | Grok (not asked) | `NotIn [shop-vip-gw]` on both clusters' `gateway-pool`; re-applied; addresses unchanged, every lease still held |
| A8 | root README: 39 directories, 38 table rows (demo 17 had no row), "39 demos" | Codex, OB1, Grok | row 17 added; stated = rows = dirs = 39 |
| A9 | gotcha #118 is on PR #44's branch, not `main` | all three | every reference reads "gotcha #118 (PR #44)" |
| A10 | the transcript was stale against the README's quotes (`poc1 holder=…` vs the older row text; `--status` shown as raw `get lease` and "BOTH") | OB1 F6, Grok | check, `--status` and the two flips re-recorded through `record.sh`; quotes verbatim; `grep 'announced by: BOTH'` → 0 |
| A11 | the VIP marker is the Gateway *name* (`io.cilium.gateway/owning-gateway`), so another namespace's `shop-vip-gw` would match | Codex C1 | **documented as a known limitation**, not changed (below) |

## Findings rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| A unique VIP marker via `spec.infrastructure.labels` propagated to the Service | Codex fix 1 | Not measured on Cilium 1.20.2 (does the Gateway's `infrastructure.labels` reach the generated Service?); the lab has one `shop-edge` namespace. The hardening is named in the README for a later phase, with the measurement it needs |
| Change `record.sh` to propagate the exit code by default | Codex fix 2 | Its header states the contract: demos *prove* things by failing and record those failures under `set -e`. The opt-in keeps that; `apply.sh` is the one caller that wants strictness |
| Both clients "finish 3 nominal seconds in ~2 s" | Codex C7 | M seconds = M one-second batches; the run ends after the last batch's requests. Symmetric in both clients, rate honoured (60 requests for `20 × 3`, measured); documented instead of changed |

## Two things the review taught about the process

- Cursor's first `cleanup.sh` shim ran under **zsh**, where an exported bash function is not inherited — the fake
  `kubectl` was not on PATH and **the real cleanup ran** against both clusters (the Gateways, the pool and the
  announce policy were removed; the Secret stayed, which was the bug under test). `apply.sh` restored everything
  (and carried the new image and the `gateway-pool` selectors). Shims run under `bash` with a PATH stub, never an
  exported function under the login shell ([[zsh-brace-every-variable]] again, in another shape).
- OB1 retracted two of its own first readings inside the pass (a zsh word-split reported 000 on every door; a hung
  `wait` was its own) — the record keeps the retractions; the final numbers are the re-runs.

After the fixes: `check.sh` 21 PASS on both clusters; the VIP announced by poc1 only (`lease holder=poc1-worker` after
the recorded flips); the lab's regression check 14 PASS (`output/regression/20260918T132455Z.txt`). Reports:
`scratchpad/review_{ob1,codex,grok}_demo40.txt`.
