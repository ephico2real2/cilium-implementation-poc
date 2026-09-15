# The observer dashboard's queries, tested offline with Loki's own engine

`go test ./...` parses every panel's LogQL with Loki 3.7.7's parser (`main.go`: every panel, the dashboard's variables
substituted) and runs the two policy panels' log pipelines on six synthetic Hubble flows — a FORWARDED flow, an L7
proxy denial (no `drop_reason_desc`), a default-deny drop, a named `POLICY_DENY`, a nameless `POLICY_DENY`, a
`SERVICE_BACKEND_NOT_FOUND` — and asserts the bucket each lands in. The dashboard file: the fork's, as the lab installs
it (`DASHBOARD=<file>` for another). The review of the upstream PR (`docs/REVIEW_OBSERVER-DASHBOARD-PANELS.md`) is where
this test came from: it fails on the queries before the review and passes on the ones after.

```bash
cd demos/25-hubble-observer-loki/logql-test && go test -count=1 ./...
DASHBOARD=/path/to/cilium-hubble-flows.json go test -count=1 ./...
```

Loki's module needs `replace github.com/hashicorp/memberlist => github.com/grafana/memberlist …` (in `go.mod`), the
same as Loki's own `go.mod`; without it `github.com/grafana/dskit/kv/memberlist` does not compile.
