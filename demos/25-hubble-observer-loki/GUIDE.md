# Demo 25 — the guide: exercises

Run from the repo root; poc1 with demos 10, 16, 19 and 24 applied. Each exercise: the command, why, what
to expect. `demos/25-hubble-observer-loki/check.sh [hours]` after each shows the state.

## Exercise 0 — the chart habit

```bash
demos/25-hubble-observer-loki/chart-prep.sh
```
*Expect:* the sources, the versions, the four default-values files refreshed, and every key of our two
values files printed against its default. Change one key in `values-loki.yaml`, run it again, find the `≠`.

## Exercise 1 — reproduce the 2.5.0 probe bug (gotcha #73)

```bash
helm template t oci://ghcr.io/onzack/helm-charts/hubble-observer --version 2.5.0 -n hubble-observer | grep -A1 -- '--server' | head -4
helm template t demos/25-hubble-observer-loki/chart/hubble-observer -n hubble-observer | grep -A1 -- '--server' | head -4
```
*Expect:* `$(HUBBLE_RELAY_HOST):$(HUBBLE_RELAY_PORT)` in the first, the FQDN in the second. Install 2.5.0
into a throwaway namespace and watch the startup probe kill a working container every 60 s.

## Exercise 2 — cause drops and watch them arrive

```bash
demos/19-zero-trust-cell/egress-test.sh poc1; demos/19-zero-trust-cell/egress-test.sh poc2
sleep 45; demos/25-hubble-observer-loki/check.sh 1
```
*Expect:* the Loki count by `flow_source_cluster_name` rising for both clusters; the dashboard's table
naming `egress-test (Pod)` in each. (The bank images are distroless — `kubectl exec … sh` cannot be the
probe; gotcha #74.)

## Exercise 3 — everything, not only drops

Set `verdictFilter: none` in `values-hubble-observer.yaml`, `helm upgrade`, wait a minute, and read the
collector's Loki exporter counters in `check.sh` and Loki's ingestion rate in Grafana Explore
(`sum(rate({container="hubble-observer"}[1m]))`). *Expect:* thousands of lines per minute — the reason
the default is DROPPED, and the reason the 24 h retention and 2 Gi volume were sized for drops. Set it back.

## Exercise 4 — the dashboard's cluster boxes

On the dashboard, type `poc2` into *Source Cluster*. *Expect:* only the poc2 probe's rows; *Flows per
Destination* shows 1.1.1.1 only. Then `poc1`: the six cell-probe destinations. That is the
`source.cluster_name` field Hubble stamps in a mesh, and the reason one observer suffices.

## Exercise 5 — generate a policy from a flow (cf2cnp)

Open a DROPPED row's link on the dashboard (or `https://cf2cnp.poc.local`), paste one flow JSON from
`kubectl -n hubble-observer logs deploy/hubble-observer --tail=1`, generate. *Expect:* a
CiliumNetworkPolicy YAML that would ALLOW that flow — read it against demo 19's `intent.yaml` before
even thinking of applying it: the cell denied that flow on purpose.

## Exercise 6 — the chart's own policy (why it is off)

`--set ciliumNetworkPolicy.enabled=true` on a `helm upgrade`. *Expect:* the observer's readiness probe
failing on DNS (`no such host`): the chart's policy allows egress to the relay only and nothing to
kube-dns. Add a DNS egress rule (demo 19's baseline shows the shape) or set it back.

## Exercise 7 — the relay behind mTLS (a window)

Follow the header of `30-relay-mtls-client-cert.yaml`: relay server TLS + mTLS on, the Certificate applied,
the observer's values switched to port 443 with the one secret. *Expect:* the observer reconnecting over
TLS with a certificate the relay's CA issued — and every plaintext `hubble` port-forward in this repo
needing `--tls --tls-ca-cert-files` from then on. Measure how long the relay is unreachable during the switch.
