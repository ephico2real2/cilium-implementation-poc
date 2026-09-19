# Demo 51 — exercises

Run from the repo root after apply.sh. poc1 and poc2 are paused — do not
resume them. No sudo.

## Prerequisites

- Demo 51 is up (`VIP_HOME=eg1`).
- poc1 and poc2 stay paused (gotcha #119).
- A route on the Mac to the lab bridge
  ([gotcha #120](../../docs/GOTCHAS.md#120)):

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

- The six names, if a client needs them without `--resolve`:

```bash
demos/51-eg-kube-vip/hosts-entries.sh
```

## Exercises

### 1. Watch the class-less Service stay pending

`probe-noclass` is the D11 exhibit: a `type: LoadBalancer` Service with
no `loadBalancerClass`. kube-vip runs class-only, so it is not claimed.

```bash
kubectl --context kind-eg1 -n shop get svc probe-noclass
```

**Expect:** `EXTERNAL-IP` stays `<pending>`. check.sh recorded the same
Service unclaimed for ≥ 30 s:

```text
  PASS   eg1 probe-noclass stays pending                                        type=LoadBalancer class=(none) ingress=(none) impl=(none) ann=(none) age=2884s D11 — class-less LoadBalancer Service stays <pending> and unclaimed for ≥ 30s
```

### 2. Move the VIP (this changes the lab)

`--status` is read-only. The move deletes `eg-vip-gw` from one cluster
and creates it on the other. Put it back on eg1; check.sh assumes that.

```bash
scripts/eg-vip-move.sh --status
scripts/eg-vip-move.sh kube-vip eg2
scripts/eg-vip-move.sh kube-vip eg1
```

**Expect:** before the move, the VIP is in eg1 and `eg1-worker` answers.
After the move to eg2, `eg2-control-plane` answers. After the move back,
`eg1-worker` answers again.

```text
== VIP 172.19.255.16 present in: eg1
  eg-vip-gw: present address=172.19.255.16 Programmed=True
  eg-vip-gw: absent
== responder MAC 6e:8c:28:fa:31:1f → eg1-worker 172.19.0.3/16
== responder MAC 1e:c6:bf:d8:18:97 → eg2-control-plane 172.19.0.4/16
```

### 3. Call a door with the wrong :authority

The `:80` listener has no hostname. The `GRPCRoute` matches
`grpc.eg1.poc.local`. A different `:authority` does not hit that route.

```bash
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg1.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg2.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check || true
```

**Expect:** the first call prints `{"status": "SERVING"}`. The second
fails — grpcurl resolves the method through reflection first, and that
call carries `:authority grpc.eg2.poc.local`, which no `GRPCRoute` on
eg1's door matches:

```text
Error invoking method "grpc.health.v1.Health/Check": failed to
query for service descriptor "grpc.health.v1.Health": server does not
support the reflection API
```

### 4. Curl each door

```bash
curl -s --resolve api.eg1.poc.local:443:172.19.255.240 \
  --cacert .tmp/eg-root-ca.crt https://api.eg1.poc.local/healthz
curl -s --resolve api.eg2.poc.local:443:172.19.255.176 \
  --cacert .tmp/eg-root-ca.crt https://api.eg2.poc.local/healthz
curl -s --resolve api.eg.poc.local:443:172.19.255.16 \
  --cacert .tmp/eg-root-ca.crt https://api.eg.poc.local/healthz
```

**Expect:** `200` and `X-Served-By` from the cluster that holds the door.

```text
https://api.eg1.poc.local @ 172.19.255.240 → 200 X-Served-By=eg1
https://api.eg2.poc.local @ 172.19.255.176 → 200 X-Served-By=eg2
https://api.eg.poc.local @ 172.19.255.16 → 200 X-Served-By=eg1
```

### 5. Run the check

```bash
demos/51-eg-kube-vip/check.sh
```

**Expect:** 39 PASS, 0 FAIL.

```text
demo 51 check: 0 FAIL
```

## Clean up

See [README.md](README.md) *Clean up*. The lab stays.

```bash
demos/51-eg-kube-vip/cleanup.sh
```
