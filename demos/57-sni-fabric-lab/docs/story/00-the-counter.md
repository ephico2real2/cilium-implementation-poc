# Chapter 0 — "The counter works"

**Fabric Coffee** has one counter. A customer orders a coffee on a web page; the order is saved
in Postgres, announced on IBM MQ, and a worker marks it processed. Every hop goes through
Envoy: one TLS port for everything outside, a mesh of listeners inside. This chapter is the
lab as it stands on 2026-10-21, before Release 1.

## What we can show

From the recorded run (`output/transcript.txt`, `scripts/run.sh --fresh`):

| Fact | Measured |
|---|---|
| The whole shop builds and checks itself from nothing | 5 min 35 s, 65 checks, 0 failures |
| An order goes from created to processed | in 1 s |
| Two minutes of customers (`scripts/load.py --seconds 120`) | 240 orders, 240 repeats answered from the first order, 240 pings, 24 strangers turned away at the door (unknown SNI, reset) |
| Half of the worker's updates fail (chaos at 50%) | all 10 orders still processed; Envoy retried 9 times |
| MQ goes down while a customer orders | the order is taken; the sweeper re-sends its event and it is processed 6 s after MQ is back |
| The TCP service stops | the API answers 502 at once, and works again when the service returns |
| Memory for the whole shop | MQ 1.139 GB under emulation; every other part under 105 MB |

## What we cannot answer yet

We can count. We cannot explain.

- **Where did an order spend its time?** We have each service's total latency, not one order's
  path through API, Postgres, MQ, the worker and Envoy.
- **Why did order 600 wait 75 seconds?** On 2026-10-21 an order created seconds after an Envoy
  restart stayed `created` until the sweeper re-sent its event. Finding out took reading three
  containers' logs by hand and lining up counters by time; the most likely cause (a REST get
  left waiting inside MQ that took the event) could not be proven, because the restart had
  discarded Envoy's old log.
- **Which retry rescued which request?** Envoy counts retries per cluster; nothing ties a retry
  to the order it saved.
- **Is a spike on the dashboard one bad order or many?** A graph cannot open the requests
  behind it.

## Next chapter

[Release 1, "Turn the lights on"](../roadmap/BACKLOG.md): one OpenTelemetry Collector, traces in
Tempo (and VictoriaTraces, compared), metrics in VictoriaMetrics beside Prometheus, logs in
VictoriaLogs, all linked by trace id. Its exit test is the question about order 600: one
order, one trace, with its logs one click away.
