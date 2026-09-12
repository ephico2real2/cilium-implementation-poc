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

## Exercise 6 — the chart's own policy (why it is off, and the fix)

`--set ciliumNetworkPolicy.enabled=true` on a `helm upgrade` of the vendored chart. *Expect:* the
observer never Ready — first because its DNS is denied (no rule), and, once you add one, because the
relay rule names the Service port 443 while Cilium enforces egress on the relay pod's port 4245
(gotcha #76): `hubble observe --from-pod hubble-observer/ --verdict DROPPED` shows both. Then install
the fork branch of PR #9 with the policy on and watch DNS and `:4245` turn `FORWARDED`. Set it back.

## Exercise 7 — prove the relay is closed, then open it for one client

```bash
kubectl --context kind-poc1 -n default run anyone --image=quay.io/cilium/hubble:v1.16.4 --restart=Never --command -- sleep 600
kubectl --context kind-poc1 -n default exec anyone -- hubble status --server hubble-relay.kube-system.svc.cluster.local:443 --tls --tls-allow-insecure
```
*Expect:* `tls: certificate required` (Part 5c). Then issue that pod a certificate the way the observer
got one (a `Certificate` from `ca-issuer` in `default`, mount the secret, `--tls-ca-cert-files`,
`--tls-client-cert-file`, `--tls-client-key-file`): *expect* `Connected Nodes: 7/7`. Delete the pod.
Finally revoke by deleting the Certificate and its Secret and restarting the pod: the CLI does not
reload certificates, and a client without one is back to `certificate required`.

## Exercise 8 — rotate the operator credential

`kubectl -n kube-system delete secret hubble-cli-client-certs` on poc1; `scripts/hubble-tls.sh kind-poc1`
again. *Expect:* cert-manager reissues within seconds (a new `notBefore`), the helper fetches the new
files, every script keeps working. The 90-day duration is the point: an operator credential that
renews itself and is never copied by hand.

## Exercise 9 — read the two new panels against demo 19's intent

Run `demos/19-zero-trust-cell/egress-test.sh poc1`, wait a minute, open the extended dashboard.
*Expect:* *Flows per Drop Reason* splits `POLICY_DENIED` (nothing allowed it: the world, another
namespace) from `POLICY_DENY` (an explicit deny: the API server), and *Flows per Denying Policy*
names `bank-cell-baseline` for the latter only. Then remove the `egressDeny` from `intent.yaml`,
re-render and re-apply the cell: the API-server drops move from `POLICY_DENY` to `POLICY_DENIED`
and the policy panel goes empty — the difference between "denied by rule" and "not allowed".

## Exercise 10 — is the image maintained? (ask this of every image)

```bash
curl -s "https://quay.io/api/v1/repository/cilium/hubble/tag/?specificTag=v1.16.4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tags"][0]["last_modified"])'
docker run --rm --entrypoint hubble quay.io/cilium/hubble:v1.16.4 version
trivy image --severity CRITICAL,HIGH quay.io/cilium/hubble:v1.16.4 | tail -20
trivy image --severity CRITICAL,HIGH quay.io/cilium/cilium:v1.20.1 | grep -A3 "usr/bin/hubble"
```
*Expect:* a 2024 push date, an end-of-life Go, CRITICAL findings — and none in the agent image's CLI.
Then `kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}'`:
that digest is what the observer should run, and it moves when Cilium moves (demo 01's pinning rule).

