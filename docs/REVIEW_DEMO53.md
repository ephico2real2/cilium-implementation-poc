# Review — demo 53, gRPC parity on the Cilium clusters (2026-09-18)

Two model reviewers and the orchestrator on one brief (`scratchpad/review_brief_demo53.md`, eight claims): **Codex**
(gpt-5.6-sol xhigh — sandbox without cluster or Docker access; live verdicts from the transcript and the read-only
results Cursor's session had retained; code and spec findings measured), **Grok** (Cursor `cursor-grok-4.6-high-fast`,
with cluster access — ran demo 40's check and the shims). **OB1 could not run: the Fable usage limit (HTTP 429), the
second demo in a row** (demo 41's pass is owed too). Every accepted finding was re-read against the code by the
orchestrator before Cursor applied it from the reviewer's snippet; the behavioural ones re-measured after.

Under review: branch `demo-53-grpc-parity`, one commit on `4830349` (`3b8b0c7`) before the fixes.

## What held

| Claim | Evidence |
|---|---|
| C1 the three listeners | `shop-gw` on poc2: `https:443 api.poc2.shop.poc.local (shop-tls)`, `https-grpc:443 grpc.poc2.shop.poc.local (grpc-tls)`, `http:80` — `3/3 listeners Programmed`; the Gateway API rule *"Combination of port, protocol and hostname must be unique for each listener"* (vendored `gateway_types.go:251`); SNI hands each name its own leaf (`grpc-tls` CN/SAN `grpc.poc2.shop.poc.local`, issuer `clustermesh-root-ca`) |
| C2 the route | two parentRefs (`https-grpc`, `http`), one hostname, three method matches → `grpc:9090`; `accepted=2/2 resolved=2/2` |
| C3 the policy | `fromEntities: [ingress]` on TCP/9090 only; demo 41's `default-deny-ingress` selects `part-of: shop` and `ingress: [{}]` is default-deny (Cilium `Documentation/security/policy/intro.rst:43-51`, gotcha #80) |
| C4 `check.sh` | 11 rows, exit = FAIL count; the root exported live from `cert-manager/clustermesh-root-ca` (both clusters `F4:FD…`); a failing `docker` → FAIL rows; grpcurl: *"It is an error to use both -authority and -servername"* — `-authority` alone sets `:authority` and the TLS server name |
| C5 poc1 | `lab-stack.sh:67` applies only demo 09's `01-gateway.yaml` — poc1 had **no** GRPCRoute; `apply.sh` restores `02-apps.yaml` + `03-routes.yaml` and the README says so; CI builds `routedemo:local` (`lab-images.sh`) before the demo 53 step |
| C8 nothing else moved | demo 41's `check.sh` 33 PASS; the regression rows 1–14 unchanged |

## Findings, accepted and applied

| # | Finding | From | Fix, measured |
|---|---|---|---|
| A1 | `apply.sh` truncated the transcript (`: > "$TRANSCRIPT"`), so the first-apply Hubble `DROPPED` line and the `openssl verify` results quoted in README/RECAP existed in **no artefact** — the house rule broken | Grok F1, Codex C7 | apply appends with a run header; **`policy-proof.sh`** (recorded, reversible: delete the CNP → grpcurl fails → Hubble `Policy denied DROPPED` from identity 8 `reserved:ingress` → re-apply → `SERVING`) and **`tls-proof.sh`** (the leaf's subject/SANs/dates; `openssl verify` OK with the live root, **failed** with `docs/root-ca.crt` — issue #60) run through `record.sh` on every apply; every quote re-taken verbatim. Codex's alternative — pasting retained console lines into the transcript — **rejected**: a transcript is what `record.sh` wrote |
| A2 | RECAP called `ingress: [{}]` "an empty allow-all" | Grok F3, Codex C7 | Cilium's wording: once selected, only explicit allows pass; the `appProtocol: kubernetes.io/h2c` detail verified on the live Service before it was claimed |
| A3 | **Cilium 1.20.2 does not appear to implement the Gateway API's cross-kind arbitration** (*"MUST accept exactly one"* of an HTTPRoute and a GRPCRoute overlapping on listener + hostname — `grpcroute_types.go:126-137`): `status_route.go` evaluates the kinds separately, `ingestion/gateway.go:194-210` appends both | Codex C2 (the single most important finding) | README/RECAP say what the code says, cited as *read*, not measured; the demo never relied on it — the distinct hostname avoids the overlap and stays portable. Not tested live on purpose (a conflicting route on the shop door) |
| A4 | regression row 15's WARN classifier `grep -qiE '(\bNotFound\b\|not found)'` also matched `bash: kubectl: command not found` | Codex C6 | WARN only on the API's `Error from server (NotFound) … grpcroutes … "grpc" not found`; shim: missing-command → FAIL (was WARN), refused → FAIL, notfound → WARN, serving → PASS. `docs/regression/README.md` "fifteen" → "sixteen" |
| A5 | `apply.sh`'s header said poc1 was read-only while the body restores demo 09 there | Codex, Grok F2 | header rewritten |
| A6 | demo 40's `check.sh` FAILed its three door rows with `200` — its phase-0 rule demanded `404`, and demo 41 attached routes | Grok C1 | rule: 404 (no routes yet) or 200 (routes attached — demo 41); 000 fails; demo 40's check 21 PASS again |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| Append "retained evidence" blocks to the transcript by hand | Codex fix C7 | the transcript's whole value is that `record.sh` wrote it; a reproducible recorded proof replaces the memory |
| Apply a same-hostname GRPCRoute to demonstrate the arbitration gap | (implied by C2) | it would put a conflicting route on the shop door; the code reading is cited as such |

After the fixes: demo 53 `check.sh` **10 PASS, 0 FAIL, 1 WARN** (no local `grpcurl`); demo 40 `check.sh` 21 PASS; demo 41
`check.sh` 33 PASS; the regression **16 PASS, 0 FAIL, 0 WARN** with row 15 `gRPC answers through a Cilium door →
SERVING`. Reports: `scratchpad/review_{codex,grok}_demo53.txt`. **Owed: OB1's pass** (demos 41 and 53).
