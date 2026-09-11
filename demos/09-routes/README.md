# Demo 09 — Wildcard TLS, DNS, and three route types on one Gateway

## Summary context

**What this demo shows.** One Cilium Gateway, one address, serving:

| Protocol | Route kind | Hostname | Certificate |
|---|---|---|---|
| HTTPS | `HTTPRoute` | `web.poc.local`, `anything-at-all.poc.local` | **wildcard** `*.poc.local` |
| HTTPS | `HTTPRoute` | `exact.example.test` | **single-name** |
| gRPC (h2c and TLS) | `GRPCRoute` | `grpc.poc.local` | wildcard |
| HTTP | `HTTPRoute` | all of the above, by `Host` | none |
| raw TCP | `TCPRoute` | — | none |

Every certificate is issued by **cert-manager from the enterprise root of demo 08** — nobody writes
a `Certificate` object; annotating the Gateway is enough. And every HTTPS test below **verifies the
chain against that root** instead of using `curl -k`, because gotcha #7 is what happens when you
skip the check the real client performs.

**Three applications, one binary.** `app/main.go` is a single Go program with a `-mode` flag —
`http`, `grpc` or `tcp` — built once into a 14 MB distroless image and run three times with
different arguments. That keeps the *route type* the only variable between the three workloads.
The gRPC side registers grpc-go's standard `grpc.health.v1.Health` service plus reflection, so it is
a real HTTP/2 + protobuf service with **no `.proto` file and no codegen**, callable by `grpcurl`.
Every response names the app that served it, so the output is the evidence.

All output is in [`output/transcript.txt`](output/transcript.txt).

---

## Part 1 — build and load the image

```bash
docker build -t routedemo:local -f demos/09-routes/app/Containerfile demos/09-routes/app
kind load docker-image routedemo:local --name poc1
```

```
image size: 14.1MB
Image: "routedemo:local" ... not yet present on node "poc1-worker", loading...
```

`kind load` copies the image into every node's containerd — no registry needed. The Deployments
use `imagePullPolicy: Never` so a missing image **fails visibly** rather than trying to pull a
name that exists nowhere.

> **Gotcha — match the Go image to the module.** `go mod tidy` on a newer local toolchain can bump
> the `go` directive in `go.mod` above the version in `FROM golang:X-alpine`, and the build then
> fails on a version mismatch. The build command reads the directive and pins the image to it.

## Part 2 — one Gateway, four listeners, cert-manager on the front

`01-gateway.yaml`, the parts that matter:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: ca-issuer      # <- this is how certificates happen
    io.cilium/lb-ipam-ips: "172.18.255.202"        # pinned (gotcha #13)
spec:
  listeners:
    - name: https-wildcard
      protocol: HTTPS
      port: 443
      hostname: "*.poc.local"
      tls: {mode: Terminate, certificateRefs: [{kind: Secret, name: wildcard-poc-local-tls}]}
    - name: https-exact
      protocol: HTTPS
      port: 443
      hostname: "exact.example.test"
      tls: {mode: Terminate, certificateRefs: [{kind: Secret, name: exact-example-test-tls}]}
    - name: http
      protocol: HTTP
      port: 80
    - name: tcp-echo
      protocol: TCP
      port: 9000
      allowedRoutes: {kinds: [{kind: TCPRoute}]}
```

**Two HTTPS listeners on the same port** are told apart by **SNI** — the hostname the client
presents in the TLS handshake. That is what lets one address serve many names with different
certificates.

**`exact.example.test` is deliberately outside `poc.local`.** If the "exact" listener had been
`api.poc.local` it would *also* be matched by the wildcard and the demo would prove nothing.

cert-manager needs one setting to watch Gateways (no feature gate since 1.15):

```bash
helm upgrade cert-manager jetstack/cert-manager -n cert-manager --reuse-values \
  --set config.gatewayAPI.enabled=true
```

Apply, and cert-manager issues both certificates from the listener hostnames, unprompted:

```bash
kubectl apply -f demos/09-routes/01-gateway.yaml
kubectl -n routes get certificate
```

```
NAME                     READY   SECRET                   AGE
exact-example-test-tls   True    exact-example-test-tls   5s
wildcard-poc-local-tls   True    wildcard-poc-local-tls   5s
```

Five seconds. What they contain, and who signed them:

```
wildcard-poc-local-tls     DNS:*.poc.local            issuer=CN=clustermesh-root-ca
exact-example-test-tls     DNS:exact.example.test     issuer=CN=clustermesh-root-ca
```

```bash
kubectl -n routes get gateway routes-gw
```

```
NAME        CLASS    ADDRESS          PROGRAMMED   AGE
routes-gw   cilium   172.18.255.202   True         5s
```

## Part 3 — DNS: three options, in order of honesty

The Gateway matches on hostname, so requests need a name. On a laptop you have three choices.

### 3a. No DNS at all — `curl --resolve` (what the transcript uses)

```bash
curl --resolve web.poc.local:443:172.18.255.202 https://web.poc.local/
```

`--resolve` pins one name to one address for that request only, so SNI and `Host` are correct
without touching the system. It is the right tool for a reproducible transcript: nothing on the
machine changes, and the evidence cannot be contaminated by a stale `/etc/hosts` line.

### 3b. Real names for a browser — `/etc/hosts` (needs sudo, run it yourself)

```bash
sudo sh -c 'printf "\n# cilium-kind-poc demo 09\n172.18.255.202 web.poc.local anything-at-all.poc.local grpc.poc.local exact.example.test\n" >> /etc/hosts'
```

Then `https://web.poc.local/` works in a browser — after you trust the root (Part 7).

**`/etc/hosts` cannot express a wildcard.** Every name must be listed. That is fine for four names
and useless for "any subdomain", which is the next option.

### 3c. True wildcard DNS — dnsmasq (needs sudo; documented, not run here)

```bash
brew install dnsmasq
echo 'address=/.poc.local/172.18.255.202' >> "$(brew --prefix)/etc/dnsmasq.conf"
sudo brew services start dnsmasq
sudo mkdir -p /etc/resolver
sudo sh -c 'echo "nameserver 127.0.0.1" > /etc/resolver/poc.local'
```

`address=/.poc.local/` answers **every** `*.poc.local` with the Gateway address, and the
`/etc/resolver/poc.local` file tells macOS to send only that domain to dnsmasq. This is the option
that makes the wildcard *certificate* useful with a wildcard *name*: invent `foo.poc.local`, add an
HTTPRoute, and it resolves and terminates TLS with no further change.

## Part 4 — HTTPRoute over HTTPS: wildcard vs exact, chain-verified

The root CA is exported once so `curl --cacert` can verify against it:

```bash
kubectl -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > root-ca.crt
```

```bash
for h in web.poc.local anything-at-all.poc.local exact.example.test; do
  curl --cacert root-ca.crt --resolve "$h:443:172.18.255.202" "https://$h/" -w '  [http=%{http_code}]\n'
done
```

```
web.poc.local              {"app":"web","mode":"http","path":"/","host":"web.poc.local","method":"GET","proto":"HTTP/1.1","tls":true}   [http=200]
anything-at-all.poc.local  {"app":"web","mode":"http","path":"/","host":"anything-at-all.poc.local","method":"GET","proto":"HTTP/1.1","tls":true}   [http=200]
exact.example.test         {"app":"web","mode":"http","path":"/","host":"exact.example.test","method":"GET","proto":"HTTP/1.1","tls":true}   [http=200]
```

Read the second line carefully: **`anything-at-all.poc.local` has no certificate of its own.**
It is served by the wildcard cert, chain-verified, and the app's `"tls":true` (from
`X-Forwarded-Proto`) confirms it came in over the HTTPS listener. That is the wildcard doing its job.

### The negative test — the one that proves the exact listener is exact

```bash
curl --cacert root-ca.crt --resolve nobody.example.test:443:172.18.255.202 https://nobody.example.test/
```

```
[http=000]  curl exit 35
```

`exit 35` is a TLS handshake failure. `nobody.example.test` matches no listener hostname and no
certificate SAN, so the Gateway cannot present a certificate for it and verification fails —
**which is exactly what should happen.** A wildcard for `*.poc.local` does not leak onto
`*.example.test`, and the single-name certificate does not cover its neighbours.

## Part 5 — GRPCRoute, both plaintext and TLS

`grpcurl` is not installed locally; a container on the docker network stands in.

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.poc.local 172.18.255.202:80 grpc.health.v1.Health/Check
```

```
{
  "status": "SERVING"
}
```

That is gRPC over **h2c** (HTTP/2 cleartext) on the `:80` listener. `-authority` sets the HTTP/2
`:authority` pseudo-header, which is what the `GRPCRoute`'s `hostnames` matches on.

Over TLS, through the wildcard certificate, chain-verified:

```bash
docker run --rm --network kind -v "$PWD:/certs:ro" fullstorydev/grpcurl:latest \
  -cacert /certs/root-ca.crt -authority grpc.poc.local 172.18.255.202:443 grpc.health.v1.Health/Check
```

```
{
  "status": "SERVING"
}
```

And because the route also forwards the reflection service, a client can discover the API with no
`.proto`:

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest -plaintext -authority grpc.poc.local 172.18.255.202:80 list
```

```
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
```

**What `GRPCRoute` gives you that `HTTPRoute` does not:** matching on the gRPC **service and
method** (`grpc.health.v1.Health/Check`), not just a path prefix. The route file matches
`grpc.health.v1.Health` and the two reflection services by name.

> **The line that makes gRPC work at all:** the Service declares
> `appProtocol: kubernetes.io/h2c`. Without it the Gateway speaks HTTP/1.1 to the pod and every
> call fails with a protocol error that looks like an application bug.

## Part 6 — TCPRoute, and the CRD-discovery gotcha

Raw TCP has no hostname, no path and no method, so a `TCPRoute` binds to its listener **by name**:

```yaml
spec:
  parentRefs:
    - name: routes-gw
      sectionName: tcp-echo
```

```bash
(echo "ping from the laptop"; sleep 1) | nc -w 5 172.18.255.202 9000
```

```
hello from echo (tcp echo)
echo echoed: ping from the laptop
```

Bytes in, bytes out, through the same Gateway address on port 9000.

### But it did not work the first time — supported ≠ installed ≠ discovered

Three separate facts, and all three have to be true:

1. **Supported.** `kubectl get gatewayclass cilium -o jsonpath='{.status.supportedFeatures}'`
   lists `TCPRoute`, `TLSRoute` and `UDPRoute`. Cilium can do it.
2. **Installed.** The `TCPRoute` CRD is in Gateway API's **experimental** channel. The standard
   channel installed in demo 05 does not include it:
   ```bash
   kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/experimental/gateway.networking.k8s.io_tcproutes.yaml
   ```
3. **Discovered.** After installing the CRD, the `TCPRoute` was accepted by the API server —
   and then silently ignored. `attachedRoutes=0`, and **no `status.parents` at all**. The
   operator's log had never once mentioned TCPRoute.

   Cilium's operator checks which Gateway API CRDs exist **when it starts**, and only runs
   controllers for those. A CRD installed afterwards is invisible until a restart:

   ```bash
   kubectl -n kube-system rollout restart deployment/cilium-operator
   ```

   ```
   "Checking for required and optional GatewayAPI resources"
   "TCPRoute CRD is installed, TCPRoute support is enabled"
   ```

   ```
   routes-gw/tcp-echo:  Accepted=True  ResolvedRefs=True
   tcp-echo attachedRoutes=1
   ```

**Also:** `v1alpha2` TCPRoute is deprecated in Gateway API 1.6.1 — the CRD's storage version is
`v1`. The route file uses `gateway.networking.k8s.io/v1`.

## Part 7 — trusting the root in a browser (optional)

`curl --cacert` verifies without changing the machine. For a browser, import the root once:

```bash
open root-ca.crt        # macOS Keychain Access -> import, then set "Always Trust"
```

After that, `https://web.poc.local/` (with the `/etc/hosts` line from 3b) shows a valid padlock
issued by `clustermesh-root-ca`.

## What to take away

| Claim | Evidence |
|---|---|
| cert-manager issues Gateway certs from one annotation | 2 certs `READY` in 5 s, both `issuer=CN=clustermesh-root-ca` |
| A wildcard cert covers names never configured | `anything-at-all.poc.local` → 200, chain-verified |
| An exact cert is exact | `nobody.example.test` → TLS failure, exit 35 |
| Two certs on one port | SNI selects `*.poc.local` vs `exact.example.test` on :443 |
| `HTTPRoute` | 3 hostnames → `web`, 200 over both HTTPS and HTTP |
| `GRPCRoute` | `Health/Check` → `SERVING` over h2c **and** TLS; reflection lists services |
| `TCPRoute` | echo round-trip on :9000 |
| One image, three protocols | `routedemo:local`, 14 MB, `-mode http\|grpc\|tcp` |

## Clean up

```bash
kubectl delete -f demos/09-routes/03-routes.yaml -f demos/09-routes/02-apps.yaml -f demos/09-routes/01-gateway.yaml
```
