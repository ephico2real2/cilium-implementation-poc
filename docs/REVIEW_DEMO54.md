# Review — demo 54, one cluster `eg-poc1`: kube-vip + Envoy Gateway API, HTTP and gRPC on two doors (2026-09-19)

Three reviewers on one brief (`scratchpad/review_brief_demo54.md`, eight claims: the guide's one-cluster lab; the two
isolated doors; kube-vip's L2 announcement seen from Docker; the MacBook's clients; the browser and the demo database;
`check.sh`; the docs; what must not have moved), judged against the operator's own words for this demo — *"show that it
works and document what we did in docker and proof that kube-vip can do the L2 announcements and that the application is
accessible externally from our clients running on the macbook and in the browser"* — with no fail-case rows, moves or
MetalLB to propose. **OB3** (`.claude/agents/ob3.md`, Opus 5; 92 tool uses, 33 min; deep on C1 with a stub harness
diffing the no-argument path at `a7ed0cf` against HEAD — 108 identical calls — C3 with the live ARP/eth0/logs, kube-vip
v1.2.4's source and kubectl's tail semantics, C5 with Chrome timed by a file watcher, C6 with two adversarial stubs);
**Codex** (sandbox without cluster, Docker or file writes; code findings measured, live verdicts PLAUSIBLE); **Grok**
(Cursor `cursor-grok-4.6-high-fast`; every shell call rejected — the tree, the transcript and the PNG). Every accepted
finding was re-verified by the orchestrator live or in the sources before Cursor applied it from the reviewer's snippet.

Under review: branch `demo-54-eg-poc1` at `1fee3fa` (one commit on `a7ed0cf`).

## What held on the wire (OB3 and the orchestrator, live)

| Claim | Evidence |
|---|---|
| the one-cluster lab (C1) | `eg-up.sh eg-poc1` mints its own root (`91:84:DE…`), exports `.tmp/eg-poc1-root-ca.crt`; `eg1 eg-poc1`, `EG1`, an argument with a space → exit 2 with zero stub calls; the no-argument path identical to `a7ed0cf` call for call |
| two isolated doors (C2) | Gateways Programmed at `.100`/`.101` = the Services' ingress; both `loadBalancerClass: kube-vip.io/kube-vip-class`, `externalTrafficPolicy: Local`; HTTPRoute parents `http-gw` only, GRPCRoute `grpc-gw` only, `attachedRoutes=1` each; from a client on `kind-eg`: gRPC at `.100:80` → "server does not support the reflection API" exit 1, `Host: api…` at `.101:80` → 404 |
| L2 in Docker (C3) | `arping -b` 3/3 from `fa:1f:d6:0f:1e:ae` = `eg-poc1-worker` for both; both `/32 scope global deprecated` on the worker's `eth0`; the mechanism in kube-vip v1.2.4 `pkg/vip/address.go:172-176` (`PreferedLft = 0` — *"so it isn't used as source address according to RFC 3484"*, `ValidLft = math.MaxInt`) |
| the MacBook (C4) | `-s --cacert`, never `-k`; grpcurl pinned `@v1.9.4`, no binary on the Mac; every curl assignment `\|\| rc=$?`-guarded; 200 + `X-Served-By=eg-poc1` on http and https, `/orders` 200 with three rows, SERVING on h2c and TLS, `list` with three services |
| the browser (C5) | `browser.png` 30,783 B 1000×500, opened by all three: shopapi's `/orders` page with the three rows; Chrome 153 writes it after 1.40 s and then hangs |
| nothing else moved (C8) | 26 files in the diff; poc1/poc2 `Exited (137)`; `kind` 172.18.0.0/16 ip-range /17 untouched; `kind-eg` 172.19.0.0/16, nodes `.0.2/.0.3` |

## Findings, accepted and applied

| # | Finding | From | Fix, measured |
|---|---|---|---|
| A1 | **the record never carried `.100`'s `successful add IP`** — `kubectl logs -l <selector>` defaults to the last 10 lines per pod and the worker's line was 11th from its end, while the README described the full sequence for each door (OB3's most important finding; Grok saw the symptom) | OB3 F1, Grok 2 | `--tail=-1 --prefix` and a present/ABSENT line per phrase; the fourth apply records both pods' watcher `adding VIP` at 13:14:15 and the worker's `successful add IP address=172.19.255.100` at 13:14:26.716945797Z. `tests/apply54-l2-logs.sh` |
| A2 | `check.sh`: row 1 accepted any slash-less string (`True` → `ready=True` PASS); the eth0 rows looped every node with an unanchored grep (a `/32` on the wrong node, or `.100/24`, → PASS); the curl rows ignored a failing `rc` when the headers parsed (rc 18 → PASS); the `/orders` row leaked a traceback on non-JSON | OB3 F2, Codex F1, Grok | `^[0-9]+/[0-9]+$` and ready == desired > 0; `arping_check` maps the MAC to the node and the eth0 rows check THAT node with `inet <ip>/32`; `rc=0` required; `2>/dev/null`. `tests/check54-contract.sh` cases (d)(e) + the five bad inputs |
| A3 | **`cleanup.sh` deleted the Gateways, then the kube-vip cloud-provider, without waiting for the door Services** — they carry `service.kubernetes.io/load-balancer-cleanup`, which only the provider clears (demo 51 review A1's class); demo 51's `cleanup.sh` had the same order | OB3 V1/F6 | `kubectl wait svc -l gateway.envoyproxy.io/owning-gateway-name… --for=delete --timeout=60s` before the provider goes (no match: 0.111 s), in both demos. `tests/cleanup54-order.sh` |
| A4 | `browser_shot` waited the full 60 s for a PNG written after 1.40 s, and its message claimed "after writing the file" when no file was written (first apply) | OB3 F5, Grok | Chrome in the background, the wait is for the FILE (size stable across two polls — the orchestrator's addition: `-s` is true on the first bytes), then Chrome is killed; "screenshot written after N s" or "no screenshot written within 60 s". Fourth apply: 2.0 s, `chrome_rc=0`. `tests/apply54-browser-shot.sh` |
| A5 | docs said things the record did not: `#120`'s "ping 0.881 ms" and "busybox wget → ok" were the orchestrator's hand measurements; `45-shop-db.yaml`'s header asserted a 503 the second run's probe never printed (the body, not the status); "/orders had been 503 in every demo" rested on one line; the GUIDE's exercise 1 asked for a `/etc/hosts` edit under the label "read-only" | Grok 3, Codex F3/F4, OB3 F3/F4 | removed / reworded from the record (`main.go:122` is the 503; demo 41 README:125 the measured one); the hosts block is the one operator (sudo) prerequisite. `tests/demo54-claims.py` |
| A6 | why one node holds both VIPs was not explained | Grok, Codex, OB3 | measured: both Envoy pods and `envoy-gateway` on `eg-poc1-worker`, both Services `externalTrafficPolicy: Local`, kube-vip elects only among nodes with a ready local endpoint (`pkg/services/leader.go:98-102`, `pkg/endpoints/endpoints_generic.go:93-95`) — the worker is the only candidate; one paragraph in the README, one sentence in the RECAP |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| "`deprecated` is the `IFA_F_DEPRECATED` flag, **not** a zero preferred lifetime — `preferred_lft forever` proves it" | Grok 1, Codex C3 | kube-vip v1.2.4 `pkg/vip/address.go:172-176` sets `PreferedLft = 0` and `ValidLft = math.MaxInt`; the kernel (`net/ipv4/devinet.c` `set_ifa_lifetime`) turns the zero preferred lifetime into `IFA_F_DEPRECATED` and the infinite valid lifetime into `IFA_F_PERMANENT`, and `inet_fill_ifaddr` reports both lifetimes as infinity for a PERMANENT address — so `ip` prints `deprecated` with `preferred_lft forever`. The README's mechanism stands; it gained the reconciliation sentence with both sources |
| anything adding fail-case rows, moves or MetalLB | — | the operator's brief for this demo |

After the fixes: the fourth `apply.sh` (idempotent, everything `unchanged`/`configured`; the L2 blocks complete; the
screenshot in 2.0 s), `check.sh` **15 PASS, 0 FAIL** recorded 2026-09-19T15:12:49Z; every test under `tests/*54*`,
`tests/eg-up-labs.sh`, `tests/eg-up-root-home.sh` and `tests/readme54-verbatim.py` PASS under bash; every `.md` 0 issues.
Reports: `scratchpad/review_ob3_demo54.txt`, `scratchpad/review_codex_demo54.txt`, `scratchpad/review_grok_demo54.txt`.
**Owed: OB1/OB2's second reading of OB3's passes (demos 50, 51, 54)** and OB1's passes on 41 and 53 when the Fable quota
resets.
