# The dashboard loop without a cluster

Loki 3.6.12 and Grafana 13.2.1 (the lab's versions) in docker compose, the observer's dashboard provisioned from a
file with the lab's input resolution, and the observer's own flow lines replayed into Loki stamped over the last
half hour. A panel change is a file edit and a page reload; the CI run (eighty minutes) stays the gate, this is the
loop. It fits a 2 CPU / 8 GB Docker VM.

```bash
demos/25-hubble-observer-loki/local-loop/up.sh                       # the fork's dashboard, the last artifact's lines
demos/25-hubble-observer-loki/local-loop/replay.py captures/observer-flows.ndjson --minutes 25
docker compose -f demos/25-hubble-observer-loki/local-loop/compose.yaml down -v
```

Where the lines come from: every CI run keeps the observer pod's stdout for its last 40 minutes in the artifact as
`captures/observer-flows.ndjson` (`gh run download <id> -n lab-observability`); any `hubble observe -o json` capture
works too; a second release's stream is replayed with `--container hubble-observer-verdicts`. Nothing is invented:
what is not in the files is not in Loki, so a panel that needs a kind of flow the files lack stays empty here — that
is the file's gap, not the panel's.

Not the lab: no relay and no mTLS (demo 25 Part 5 is measured on the runner), no cf2cnp behind a Gateway (the
Generate action's URL points nowhere), no Prometheus (the verdicts dashboard is metrics; this loop is for the flows
dashboard). The queries themselves are also testable with no containers at all: `../logql-test` runs them through
Loki's own engine on synthetic flows.
