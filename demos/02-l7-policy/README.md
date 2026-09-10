# Demo 02 — L7 HTTP-aware network policy

**What it proves.** Cilium can allow one HTTP method+path and deny another *between the same two
pods, on the same TCP port*. This is not a thing iptables can express. It is the clearest single
argument for an eBPF, identity-aware dataplane.

The demo is Cilium's official Star Wars app, pinned to v1.20.1:
`deathstar` (a Service with 2 replicas), `tiefighter` (`org=empire`) and `xwing` (`org=alliance`).

Run it in three stages, and **do each stage in order** — the value is in how the answer changes.

## Stage 0 — no policy

```bash
kubectl apply -f demos/02-l7-policy/http-sw-app.yaml
kubectl wait --for=condition=Ready pod --all --timeout=180s
```

```bash
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
kubectl exec xwing      -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```

```
Ship landed
Ship landed
```

Both land. There is no policy, so everything is permitted.

Worth noticing in passing: that request resolved a Kubernetes Service and was load-balanced to one
of two backends **with no kube-proxy in the cluster**. Cilium did it in eBPF.

## Stage 1 — L3/L4 policy, and the gap it leaves

```bash
kubectl apply -f demos/02-l7-policy/01-l3-l4-policy.yaml
```

```bash
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```

```
Ship landed
```

```bash
kubectl exec xwing -- curl -s -XPOST --max-time 8 deathstar.default.svc.cluster.local/v1/request-landing
```

```
command terminated with exit code 28      # curl timeout — the packet was dropped
```

The rule matched on the **label** `org=empire`, not on an IP, so it survives rescheduling.

**Now the gap.** tiefighter is allowed on TCP 80. What stops it calling the dangerous endpoint?

```bash
kubectl exec tiefighter -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
```

```
Panic: deathstar exploded

goroutine 1 [running]:
main.HandleGarbage(0x2080c3f50, 0x2, 0x4, 0x425c0, 0x5, 0xa)
        /code/src/github.com/empire/deathstar/temp/main.go:9 +0x64
```

Nothing stopped it. A port-level rule cannot see a URL — the connection it authorised was used for
a request it never had the vocabulary to describe.

## Stage 2 — L7 policy closes it

```bash
kubectl apply -f demos/02-l7-policy/02-l7-policy.yaml
```

The only change from stage 1 is a `rules.http` block permitting `POST /v1/request-landing`.

```bash
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```

```
Ship landed
```

```bash
kubectl exec tiefighter -- curl -s -XPUT -w '\n[%{http_code} in %{time_total}s]\n' \
  deathstar.default.svc.cluster.local/v1/exhaust-port
```

```
Access denied

[403 in 0.016952s]
```

Same client, same destination, same port, same security identity — **a different verb and path get
a different answer.**

### A diagnostic worth internalising

Compare the two denials:

| Denied at | Symptom | Why |
|---|---|---|
| L3/L4 (xwing) | curl **times out**, exit 28 | the SYN is dropped in eBPF; nothing ever answers |
| L7 (tiefighter → exhaust-port) | instant **403** in ~17 ms | the Envoy L7 proxy accepted the connection, parsed the request, and refused it |

So the *shape* of a failure tells you which layer refused it. A timeout smells like L3/L4; a fast
403 smells like L7.

## Stage 3 — see it in Hubble

```bash
hubble observe --last 40 -P --protocol http
```

```
default/tiefighter:38986 (ID:66741) -> default/deathstar-...:80 (ID:86276) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
default/tiefighter:38986 (ID:66741) <- default/deathstar-...:80 (ID:86276) http-response FORWARDED (HTTP/1.1 200 3ms (POST .../v1/request-landing))
default/tiefighter:38990 (ID:66741) -> default/deathstar-...:80 (ID:86276) http-request DROPPED   (HTTP/1.1 PUT  http://deathstar.default.svc.cluster.local/v1/exhaust-port)
default/tiefighter:38990 (ID:66741) <- default/deathstar-...:80 (ID:86276) http-response FORWARDED (HTTP/1.1 403 0ms (PUT .../v1/exhaust-port))
```

And the L3 denial, for contrast:

```bash
hubble observe --last 25 -P --label class=deathstar
```

```
default/xwing:51338 (ID:99365) <> default/deathstar-...:80 (ID:86276) Policy denied DROPPED (TCP Flags: SYN)
```

Note what is in those lines: pod names and numeric **security identities**, the HTTP method and
path, the verdict, and the response time. Not IP pairs and packet counts. That is the observability
half of the argument, and it comes from the same dataplane doing the enforcement.

## Clean up

```bash
kubectl delete -f demos/02-l7-policy/02-l7-policy.yaml
kubectl delete -f demos/02-l7-policy/http-sw-app.yaml
```
