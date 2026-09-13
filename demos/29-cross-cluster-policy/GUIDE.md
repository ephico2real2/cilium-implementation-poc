# Demo 29 — the guide: exercises

Run from the repo root with both clusters up and demos 24 (the relay streams the whole mesh), 25 (the
observer, cf2cnp behind the Gateway) and 26 (the helper scripts) in place. Every exercise reads before it
writes, and the one that writes tells you what it changes.

## Exercise 0 — see the cluster on a flow

```bash
kubectl --context kind-poc2 -n mesh-lab exec worker -- redis-cli -h cache PING
hubble observe -P --kube-context kind-poc1 --namespace mesh-lab --to-pod mesh-lab/cache --port 6379 --last 20 -o json \
  | python3 -c 'import json,sys
for l in sys.stdin:
    f=json.loads(l)["flow"]
    if f.get("is_reply"): continue
    print(f["node_name"], f.get("traffic_direction","-"), f["source"].get("cluster_name"), "->", f["destination"].get("cluster_name"),
          [x for x in f["source"]["labels"] if "policy.cluster" in x])'
```

*Expect:* every line names both clusters (`poc2 -> poc1`) and the source carries
`k8s:io.cilium.k8s.policy.cluster=poc2`. That label is the one the 0.6.0 selector copies. If the lab is gone,
apply `10-lab.yaml` to both clusters and `11-cache-poc1.yaml` to poc1 first (README Part 2).

## Exercise 1 — the same flows through 0.5.1 and 0.6.0

```bash
demos/26-cf2cnp-policy-from-flows/generate.sh demos/29-cross-cluster-policy/policies/flows-cache-from-poc2.ndjson /tmp/cache-0.6.0.yaml
docker run -d --rm --name cf2cnp-0.5.1 -p 127.0.0.1:28080:8080 ghcr.io/ephico2real2/cf2cnp:0.5.1 && sleep 2
curl -s -X POST http://127.0.0.1:28080/generate --data-binary @demos/29-cross-cluster-policy/policies/flows-cache-from-poc2.ndjson -o /tmp/cache-0.5.1.yaml
docker stop cf2cnp-0.5.1
diff /tmp/cache-0.5.1.yaml /tmp/cache-0.6.0.yaml
```

*Expect:* one added line, `io.cilium.k8s.policy.cluster: poc2`, under `fromEndpoints`. Everything else is
byte-identical: the enhancement changes nothing for a single cluster (README Part 5).

## Exercise 2 — the trap, on your own pods (writes: two policies in mesh-lab on poc1)

```bash
NS=mesh-lab demos/26-cf2cnp-policy-from-flows/audit-mode.sh cache Disabled
kubectl --context kind-poc1 apply -f demos/29-cross-cluster-policy/20-cache-default-deny-ingress.yaml
kubectl --context kind-poc1 apply -f demos/29-cross-cluster-policy/policies/cnp-cache-0.5.1.yaml
for c in poc2 poc1; do echo "worker@$c: $(kubectl --context kind-$c -n mesh-lab exec worker -- sh -c 'timeout 5 redis-cli -h cache PING; echo rc=$?' 2>&1 | tr '\n' ' ')"; done
demos/29-cross-cluster-policy/verdicts.sh 60
kubectl --context kind-poc1 apply -f demos/29-cross-cluster-policy/policies/cnp-cache-0.6.0.yaml
for c in poc2 poc1; do echo "worker@$c: $(kubectl --context kind-$c -n mesh-lab exec worker -- sh -c 'timeout 5 redis-cli -h cache PING; echo rc=$?' 2>&1 | tr '\n' ' ')"; done
demos/29-cross-cluster-policy/verdicts.sh 60
```

*Expect:* with the 0.5.1 policy the caller in poc2 is `Terminated rc=143` (its SYNs are `DROPPED`, no policy
named) while the twin in poc1 gets `PONG` (`ingress_allowed=cache-server`). With the 0.6.0 policy — same name,
so `kubectl apply` replaces it — the two swap. Both policies are "valid"; only one is right.

## Exercise 3 — the verdict of a policy applied in poc2, on poc1's Grafana (writes: one policy in mesh-lab on poc2)

```bash
kubectl --context kind-poc2 apply -f demos/29-cross-cluster-policy/policies/cnp-worker-poc2.yaml
kubectl --context kind-poc2 -n mesh-lab exec worker -- sh -c 'redis-cli -h cache PING; timeout 3 redis-cli -h accounts.bank.svc.cluster.local -p 80 PING'
demos/29-cross-cluster-policy/verdicts.sh 60 | grep poc2-worker
demos/29-cross-cluster-policy/metric.sh mesh-lab
```

Then open `https://grafana.poc.local/d/hubble-policy-verdicts?var-cluster=poc2&var-namespace=mesh-lab`.

*Expect:* on poc2's node, `egress_allowed=worker-batch` for DNS and for the cache, `DROPPED` for the accounts
pod (port 8080 — the pod's port, not the Service's 80); `metric.sh` prints `poc2` rows for `forwarded` and
`dropped`; the dashboard shows `worker → cache (egress) forwarded` under cluster `poc2`. The drop to `bank` is
not on that page — the dashboard filters by *destination* namespace (README Part 8).

## Cleanup

`demos/29-cross-cluster-policy/cleanup.sh` — deletes `mesh-lab` in both clusters, nothing else.
