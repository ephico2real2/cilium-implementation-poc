# Regression testing — how we prove the lab still works after a change

Written 2026-09-18 after the move from Cilium 1.20.1 to 1.20.2, in plain words. "Regression" means: something that
used to work stopped working because of a change. Regression *testing* means checking, after every change, that the
things the lab promises still happen — with real numbers from the running clusters, not with a feeling.

The lab is two kind clusters on this Mac, `poc1` and `poc2`, joined in a Cluster Mesh. Everything below was run on
them.

## The three layers of testing, and when each runs

| Layer | What it is | How long | When |
|---|---|---|---|
| **1. The quick check** — `scripts/lab-regression.sh` | fourteen questions in plain English, each answered PASS or FAIL with the number that decided it | about a minute (the two saved runs started 62 s apart) | after any change, before saying "done" |
| **2. Cilium's own connectivity test** — `cilium connectivity test --multi-cluster` | Cilium's 87 tests, 512 actions: pods talking to pods, services, the other cluster, the outside world, with and without policies | 13 minutes on this Mac | after an upgrade of Cilium itself |
| **3. The whole lab from nothing** — the `lab-observability` GitHub Action | a fresh runner builds both clusters, installs every demo, generates traffic, generates and applies policies, checks every page, screenshots every dashboard | about 55 minutes | started by hand (`gh workflow run`) on the branch that changes a version pin; the slimmer `lab-regression` Action runs by itself on a push that touches the check or the pins |

The quick check is what you run yourself. The other two are proof for a pull request.

## Layer 2, as it happened: Cilium's connectivity test on 1.20.2 (2026-09-18 00:1x → 00:2x)

The command (the `lab-regression` Action runs exactly this; the full-lab Action adds flags to collect a sysdump on
failure):

```sh
cilium connectivity test --context kind-poc1 --multi-cluster kind-poc2 --test '!no-unexpected-packet-drops'
```

(The `--test '!…'` part means "run every test except this one": the skipped test counts every dropped packet, and
on this lab there are demos whose whole point is to drop packets, so it would always complain.)

What it does, in simple words: it creates test pods in both clusters, then makes them talk to each other in 87
different ways — plain traffic, traffic with a policy that allows it, traffic with a policy that should block it,
traffic to the other cluster, traffic to a real website, DNS lookups — and for every one it checks that what should
pass passes and what should be blocked is blocked.

**Result: 86 of 87 tests passed (507 of 512 actions). Took 789 seconds.**

```text
❌ 1/87 tests failed (5/512 actions), 50 tests skipped, 0 scenarios skipped:
[cilium-test-1] 1 tests failed
exit=1 took 789s
```

The one "failed" test is not a traffic test. It is `check-log-errors/no-errors-in-logs`: at the end, the tool reads
the Cilium logs of every pod and complains if any line matches its list of worrying messages. It found eight distinct
lines (the report prints each twice), of four kinds. Every one is explained by what we did that evening:

| Message (what the log said) | When | What it means, plainly | Regression? |
|---|---|---|---|
| `Forcefully terminating sockets connected to deleted service backends not supported by underlying kernel` (4 lines: 22:26:08 and 22:26:19 on poc1, 22:33:58 and 22:34:01 on poc2) | the minutes the Cilium pods were being replaced on each cluster (the 1.20.2 rollout, pull request #34) | When a pod behind a service goes away, Cilium would like to close the connections still open to it, so clients reconnect at once instead of waiting for a timeout. That needs a kernel switch (`CONFIG_INET_DIAG_DESTROY`, "socket destroy") the Docker Desktop kernel (`7.0.12-linuxkit`, `docker exec poc1-control-plane uname -r`) does not have, so Cilium says so once per rollout and lets the connections time out on their own. Same before and after the upgrade | No — a fact about this Mac's kernel, logged during the rollout |
| `Error while getting cilium-health status … connection refused` (2 lines, 22:27:04 and 22:27:12, both on poc1, "6 occurrences" each) | seconds after poc1's new agents started | The health-checker inside the agent was asked before it had finished starting | No — startup, during the rollout |
| `Failed to retrieve flows from peer … Unavailable` (hubble-relay, 1 line, "4 occurrences") | 22:33:41 | The relay lost its connection to an agent that was being replaced, and reconnected | No — the rollout |
| `Envoy: Discarded invalid access log message … string field contains invalid UTF-8` (1 line, "225 occurrences") | 00:23:53 — *during* the test | The test sends deliberately odd requests through the L7 proxy; Envoy's access log could not encode 225 of them and dropped the log lines (the requests themselves were handled). This is the one message caused by the test, not by us | No — the test's own traffic; worth remembering if it ever shows up outside a test |

So: every traffic test passed, and the log scan found only the footprints of the upgrade itself and of the test. That
is what a clean upgrade looks like — not a silent log, but a log whose every error you can point at and name.

**How to read a run of your own:** look for the line `✅ [cilium-test-1] All 87 tests (… actions) successful` or `❌ N/87 tests failed`. If N is
not 0, find the test names after `🟥`; if the only one is `check-log-errors`, read the quoted log lines and ask of each
"when was that, and what was I doing then?".

## Layer 3, as it happened: the GitHub Action on the 1.20.2 branch

Run [35283148292](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35283148292): every step of
the lab passed on 1.20.2 — the two clusters built, the mesh, the observability stack, the demo apps, three minutes of
traffic, the generated policies applied and re-tested, the report, the screenshots. Then it was asked to run the
connectivity test too (an optional input), and 70 minutes into that step — 117 minutes into the run, 22:39 → 00:37 UTC — the GitHub runner
itself died: "The hosted runner lost communication with the server", which GitHub explains as the runner starved of CPU or memory. That is the *runner*
failing, not the lab: a 4-CPU machine carrying two clusters, the full stack and Cilium's test at once. The rerun
without the optional test is [35292022545](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35292022545);
the connectivity test was run on this Mac instead (layer 2 above), where it has 10 CPUs.

## Layer 1: the quick check — what each question means

The script prints one row per question. Here is what each row is really asking, in plain words:

| # | The row | The plain question |
|---|---|---|
| 1 | Both clusters run the expected Cilium version | Did the upgrade actually land? (We learned the hard way — gotcha #117, arriving with pull request #34 — that Helm can say "deployed" while nothing changed.) The expected version is the one the lab is built from, `scripts/bootstrap/versions.env`. |
| 2 | Every Cilium agent is healthy | Does Cilium itself say it is fine on every node? |
| 3 | The two clusters see each other | Is the Cluster Mesh link up from both sides? |
| 4 | The Gateway answers on every published address | Can a browser still reach Grafana, cf2cnp, the shops, the bank? |
| 5 | Every Gateway listener is programmed | Did every "door" of every Gateway come back after the restart? |
| 6 | The load-balancer addresses have an owner | Each public IP (Grafana's, the shops') is answered by exactly one node at a time; Cilium hands that job out as a "lease", like a library book. Is every lease held by a node right now? |
| 7 | Hubble metrics arrive from both clusters | Is the monitoring seeing traffic from poc1 *and* poc2? |
| 8 | Policy still enforces, traffic still flows | Are packets still being dropped where they should be, and forwarded where they should be? |
| 9 | The flow observer is streaming | Is the tool that records dropped flows still writing them? |
| 10 | cf2cnp answers and is the expected version | Does the policy generator respond, and is it the version we pinned? |
| 11 | Grafana has the lab's dashboards | Are all nine of our dashboards still there? |
| 12 | The tutorial dashboards' queries return data | Do the 30 tutorial panels all have data — none says "No data", and none of the queries failed outright? |
| 13 | Demo 37's two Gateway doors still behave | Are both doors up at their pinned addresses? |
| 14 | Cilium's connectivity test result | If we ran layer 2, what did it say? |

The real run after the upgrade is pasted below, unedited.

## The quick check, run 2026-09-18 after the upgrade

Run it: `scripts/lab-regression.sh` (about a minute; the table is also saved under `output/regression/`). It exits
with the number of FAIL rows, so a CI job can use it as a gate.

The very first run on `main` gave **13 PASS, 1 FAIL** — and the FAIL was right:

```text
FAIL   Both clusters run the expected Cilium version                                            poc1 v1.20.2 2/2, poc2 v1.20.2 2/2         image contains :v1.20.1@ and ready==desired on both
```

The clusters run 1.20.2 but `main` still says 1.20.1 (the pin moves in pull request #34). The check compares the
clusters to the repository, and they disagreed. That is a regression test earning its keep: it does not know what you
meant, only what the files say. With the expected version stated (`EXPECT_CILIUM=1.20.2`, or after #34 merges), the
same clusters give:

```text
== lab regression 2026-09-18T01:26:44Z — contexts kind-poc1 kind-poc2 — expected Cilium 1.20.2
  STATUS WHAT                                                                                     MEASURED                                   RULE
  PASS   Both clusters run the expected Cilium version                                            poc1 v1.20.2 2/2, poc2 v1.20.2 2/2         image contains :v1.20.2@ and ready==desired on both
  PASS   Every Cilium agent is healthy                                                            poc1 Cilium=OK Envoy=OK; poc2 Cilium=OK Envoy=OK cilium status --wait exits 0 and reads Cilium: OK, Envoy DaemonSet: OK on both
  PASS   The two clusters see each other (Cluster Mesh)                                           poc1: ✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]; poc2: ✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1] clustermesh status exits 0 and contains All 2 nodes are connected
  PASS   The Gateway answers on every published address                                           7/7 answered                               every deployed name answers 200 (bank may be 401)
  PASS   Every Gateway listener is programmed                                                     7 listeners, 7 True                        every listener Programmed=True on kind-poc1
  PASS   The load-balancer addresses have an owner (L2 leases)                                    4 leases, holders: poc1-worker poc1-worker poc1-worker poc1-worker every l2announce lease has a holder
  PASS   Hubble metrics arrive from both clusters                                                 poc1 254.7/s, poc2 81.9/s                  rate > 0 for poc1 and poc2
  PASS   Network policy is still enforcing (drops exist) and traffic still flows (forwards exist) FORWARDED 247.7/s, DROPPED 2.7/s           FORWARDED > 0 and DROPPED > 0 on poc1
  PASS   The flow observer is streaming to Loki                                                   ready 1/1, 318 lines in 2 min              ready == desired and log lines in the last 2 min > 0
  PASS   cf2cnp (the policy generator) answers and is the expected version                        health 200, image 0.9.0                    health 200 and image tag 0.9.0
  PASS   Grafana has the lab's dashboards                                                         9/9 present                                9/9 uids present
  PASS   The tutorial dashboards' queries return data                                             30 panels, 0 NO DATA                       0 NO DATA lines (count → lines as panels)
  PASS   The two Gateway doors of demo 37 still behave                                            2 doors Programmed, 172.18.255.240 / 172.18.255.243 2 Programmed=True doors with addresses
  PASS   Cilium's own connectivity test, if a result file is present                              ❌ 1/87 tests failed (5/512 actions), 50 tests skipped, 0 scenarios skipped: — only the log scan failed 0 failed, or only check-log-errors (the log scan)

summary: 14 PASS, 0 FAIL, 0 WARN — saved to output/regression/20260918T012644Z.txt
```

Read it top to bottom (the numbers are this run's): the version landed on both clusters (2 of 2 agents each), Cilium
says OK, the mesh is up from both sides, all seven public names answer, all seven Gateway listeners are programmed, the
four public addresses have an owner, monitoring sees flows from both clusters, policy is dropping some traffic while
most gets through, the observer is writing lines, cf2cnp is 0.9.0 and healthy, the nine dashboards exist, the
tutorial's 30 panels all have data, demo 37's two doors are up at their addresses, and the connectivity test's only
failure was the log scan explained above. The RULE column is the script's own one-line rule for each row, as it
prints it.

## The slim Action, as it happened — three runs in one night

The `lab-regression` Action was reviewed before its first run by OB1 (Anthropic's Fable 5.1, in Claude Code), Codex and
Grok (`docs/REVIEW_REGRESSION.md`). OB1 predicted from the code that the first run "cannot go green" and named why;
the runs then showed it:

| Run | What changed | Result | Why |
|---|---|---|---|
| [35294125733](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35294125733) — the version before the review | — | **7 PASS, 6 FAIL** | exactly OB1's list: the runner did not trust the lab's certificate (`curl: (60) SSL certificate problem`), could not resolve `grafana.poc.local` (`curl: (6)`), printed `000000` for cf2cnp, and counted 0 tutorial panels |
| [35295439873](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35295439873) — after the review's fixes | the root trusted, the names resolved, row 4 checks only deployed names, the success regex, `→ ERR` counted | **13 PASS, 0 FAIL, 1 WARN** (the WARN: the optional connectivity test was not run) — the check itself is green on a fresh machine | the one red step was the screenshot of the observer dashboard: the observer had written 36 lines, but they had not yet travelled through the log shipper into Loki, so six panels still said "No data" |
| [35296914935](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35296914935) — with a wait for Loki | the check **13 PASS, 0 FAIL, 1 WARN** again; the wait ran its full six minutes and Loki still had 0 observer lines | not timing after all: the trimmed stack had skipped `tempo` and `collectors`, and the OTel collector *is* the Loki shipper (the lab's own table says so). The observer wrote; nothing carried it |
| the fourth run | the two missing stack steps added | see issue #38 for the link | |

Three lessons for a newcomer: a reviewer who reads the code can predict a CI failure before the first run; a "No
data" panel can be **timing** (the data is on its way) — so a test that reads a dashboard must wait for the pipeline
behind it; and when the wait runs out, it is a **missing link** in that pipeline — read the component table, not the
clock.

## What "regression testing a lot" means here

Not one big test once. Three habits:

1. **Run the quick check after every change** — a Helm value, a pin, a dashboard — and paste its table into the pull
   request. One minute.
2. **Run Cilium's connectivity test after every Cilium upgrade**, on the Mac (13 minutes), and read the one failing
   test if there is one.
3. **Let the GitHub Action build the whole lab** on the branch that changes a pin, and treat the run link as the
   proof. The Action runs the quick check too, and captures the dashboards the checks touch (see
   `.github/workflows/lab-regression.yaml`).

Every number in this document is from the runs named beside it; the saved tables are under `output/regression/`. The
work is tracked in [issue #38](https://github.com/ephico2real2/cilium-implementation-poc/issues/38); the CI run's
captures show four dashboards the rows touch — the observer dashboard, *Hubble Metrics per cluster*, the L7 dashboard
keyed on the pods' `app` labels (our workaround: Cilium's own L7 dashboard keys on the workload name, which is empty for
backends on another node — cilium/cilium#25676) and the tutorial's Cilium page.
