# Demo 23 — the guide: exercises

Run from the repo root; both clusters up with demos 18, 21 and 22 applied. Each exercise is the
command, why, and what to expect. The transcript in `output/` holds the recorded run of each.

## Exercise 1 — reproduce the trap (Part 1b)

```bash
for c in poc1 poc2; do kubectl --context kind-$c -n otel annotate svc otel-collector service.cilium.io/global=true --overwrite; done
sleep 10; demos/23-collector-per-cluster/check.sh 5
```

*Why:* a global Service merges same-named backends from every cluster that annotates it. *Expect:*
seven backends on both sides. Annotate only one side first and see five: the annotation is needed
on both. Undo — **not** with `apply` (it will not remove what it never owned):

```bash
for c in poc1 poc2; do kubectl --context kind-$c -n otel annotate svc otel-collector service.cilium.io/global- service.cilium.io/affinity-; done
```

## Exercise 2 — the wrong cluster stamp

With the trap in place, run demo 20's petclinic (OTel Java agent, no cluster attribute) and search
Tempo for `{ resource.service.name = "api-gateway" && resource.k8s.cluster.name = "poc2" }`.
*Expect:* poc1's Spring Boot spans labelled poc2 — the two-in-seven that went through poc2's gateway.
Undo as in Exercise 1.

## Exercise 3 — the hub down, the queue up (Part 3)

```bash
kubectl --context kind-poc1 -n monitoring scale sts tempo --replicas=0
demos/15-bank/exercise.sh 30 chk-1001; sleep 20; demos/23-collector-per-cluster/check.sh 5
```

*Expect:* `queue=N` on the gateway that received poc2's spans, `failed=0` (retries never give up).
Note that `queue_size` only counts what no consumer has taken; small backlogs sit in the consumers'
retry loops and show as 0.

## Exercise 4 — kill the gateway, keep the spans (Part 3b)

```bash
docker exec poc2-worker crictl ps --name otel-collector -q | while read c; do docker exec poc2-worker crictl inspect $c | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["info"]["pid"])'; done | xargs -n1 docker exec poc2-worker kill -9
sleep 15; demos/23-collector-per-cluster/check.sh 5
kubectl --context kind-poc1 -n monitoring scale sts tempo --replicas=1; sleep 60; demos/23-collector-per-cluster/check.sh 5
```

*Why:* the queue lives on the pod's emptyDir; a container restart keeps it. *Expect:* `restarts`
+1, then after Tempo returns `sent>0` on a gateway whose accepted count since restart is 0.
Then remove `storage: file_storage` from the ConfigMap, restart, and repeat: the spans are gone.

## Exercise 5 — the disruption budget

```bash
kubectl --context kind-poc2 drain poc2-worker --ignore-daemonsets --delete-emptydir-data --dry-run=server 2>&1 | grep -i otel
```

*Expect:* the PDB lets one gateway go at a time; with `minAvailable: 1` on a single schedulable
node the second eviction waits until the first is rescheduled — which on poc2 it cannot be. That is
the honest limit of a one-worker cluster, and the reason the anti-affinity is `preferred`.
