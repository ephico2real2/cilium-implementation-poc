# Review record: #115, the tracing page

Issue #115, PR #116: [`docs/tracing.md`](../tracing.md) and `tests/trace_capture.py`, written by the
orchestrator on 2026-10-22. Reviewed by Codex (`gpt-5.6-sol`, `high`) and OB1-lite (Opus 5.5,
`high`), each at head `6c0d51d`; the arbitrated fixes (`508df26`) were cross-checked by both.

## First review: both NOT MERGE-READY

| Finding | From | Decision |
|---|---|---|
| "Check it yourself" failed when pasted: Tempo answers a trace it does not hold yet with an empty 200, and the order's JSON had no newline | OB1-lite (measured: order 48, `KeyError: 'resourceSpans'`) | applied: `-w '\n'`, `sleep 10`, `.get("resourceSpans", [])`; run as written in bash and zsh, orders 51 and 52, 12 names each |
| The capture could picture an incomplete trace, or a worker trace before orders-api's half arrived; a failed run left a mixed set; HTTP errors were tracebacks | Codex, OB1-lite | applied: OB1-lite's staging, FAIL lines and wait; Codex's parent checks and same span ids in both stores. Codex's exact 12-name list not taken: a library adding a span would fail a correct trace |
| The worker caption made `UPDATE` a child of the worker's `PUT` | both | applied |
| Two "What it proves" cells claimed more than the code checks | both | applied |
| The instrumentation, worker and "IBM MQ, Postgres" rows; "twice" is per store | Codex, OB1-lite | applied |
| Factor III: the image's `CMD` switches tracing on, not `OTEL_*` alone; R1.4 touches XI, does not move it | OB1-lite | applied |
| phase6's `client=1` beside the capture's `client=7` | OB1-lite | explained |
| Tempo's `<root span not yet received>` had no recorded output | OB1-lite | measured, `output/tracing-measurements.txt` section 5 |
| RECAP said every service patches FastAPI, httpx and psycopg; the chapter named one picture script | Codex | applied |

## Cross-check: both refuted the same point

A server span ends after its children, but its arrival does not prove theirs: the SDK drops a
batch whose export failed and sends the next (OB1-lite and Codex, from the installed
`BatchProcessor` and `OTLPSpanExporter`). Taken: the capture now requires the spans the page
discusses under each server span (`INSERT`, the `POST` to MQ, `UPDATE`, `SELECT`; `UPDATE` under
the status call), as Codex's lower-bound form proposed, but not the library's own spans (the pool's
checks, the ASGI sends), which can change with a library. Also taken: the resource cell (Codex;
other named services are not checked), the MQ row (both), and the chapter's picture sources
(OB1-lite).

## Testing record

| Test | Command | Pass condition | Result |
|---|---|---|---|
| Tracing checks | `scripts/verify.sh phase6` | `failures: 0` | `output/phase6-tracing.txt`, `failures: 0` |
| False-pass cases | `bash tests/scripts/test_verify_false_pass.sh scripts/verify.sh` | `mismatches: 0` | `mismatches: 0` |
| The capture's own cases, no lab | `python3 tests/scripts/test_trace_capture.py tests/trace_capture.py` | `failures: 0` | 11 ok; against `6c0d51d` and `508df26` it stops on the checks they lack |
| The capture on the lab | `python tests/trace_capture.py docs/screenshots` | six pictures, exit 0 | `output/trace-capture.txt`: order 53, 12 spans in Tempo, the same 12 span ids in VictoriaTraces, worker trace 8 spans |
| "Check it yourself" as written | the page's block, in bash and in zsh | 12 span names | orders 51 and 52, 12 names each, exit 0 |
| The page's other facts | the commands in `output/tracing-measurements.txt` | each section answers | recorded there |
