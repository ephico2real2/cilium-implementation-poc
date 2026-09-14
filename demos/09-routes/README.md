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

> **Addresses changed on 2026-09-11.** A dedicated pool was reserved for Gateways
> (`cilium/lb-ippool-poc1.yaml`): `routes-gw` moved **`.202 → .240`**, and demo 05's `sw-gateway`
> **`.200 → .241`**. Command examples below use the new addresses; **captured output quoted from
> before the change still shows the old ones** — it is a record, not an error. The live values
> always come from `scripts/hosts-entries.sh`.

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
spec:
  infrastructure:
    annotations:
      lbipam.cilium.io/ips: "172.18.255.240"       # pinned INSIDE gateway-pool (gotcha #13, corrected)
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

> `.202` is the address this capture got from the general pool **before Part 7b reserved a Gateway
> range**. The Gateway is pinned at `172.18.255.240` now; `kubectl -n routes get gateway routes-gw`
> on your cluster must show an address inside `172.18.255.240–250`.

## Part 3 — DNS: three options, in order of honesty

The Gateway matches on hostname, so requests need a name. On a laptop you have three choices.

### 3a. No DNS at all — `curl --resolve` (what the transcript uses)

```bash
curl --resolve web.poc.local:443:172.18.255.240 https://web.poc.local/
```

`--resolve` pins one name to one address for that request only, so SNI and `Host` are correct
without touching the system. It is the right tool for a reproducible transcript: nothing on the
machine changes, and the evidence cannot be contaminated by a stale `/etc/hosts` line.

### 3b. Real names for a browser — `/etc/hosts` (needs sudo, run it yourself)

Do not hardcode the address — it is read from the cluster by `scripts/hosts-entries.sh`, and Part 8
has the full procedure (write, count, flush, resolve, curl, open):

```bash
sudo sh -c 'scripts/hosts-entries.sh >> /etc/hosts'
```

Then `https://web.poc.local/` works in a browser — after you trust the root (Part 7).

**`/etc/hosts` cannot express a wildcard.** Every name must be listed. That is fine for four names
and useless for "any subdomain", which is the next option.

### 3c. True wildcard DNS — dnsmasq (needs sudo; documented, not run here)

```bash
brew install dnsmasq
echo 'address=/.poc.local/172.18.255.240' >> "$(brew --prefix)/etc/dnsmasq.conf"
sudo brew services start dnsmasq
sudo mkdir -p /etc/resolver
sudo sh -c 'echo "nameserver 127.0.0.1" > /etc/resolver/poc.local'
```

`address=/.poc.local/` answers **every** `*.poc.local` with the Gateway's address — which sits in the **reserved Gateway range** `172.18.255.240–250` (`cilium/lb-ippool-poc1.yaml`), so the wildcard can never land on a plain Service, and the
`/etc/resolver/poc.local` file tells macOS to send only that domain to dnsmasq. This is the option
that makes the wildcard *certificate* useful with a wildcard *name*: invent `foo.poc.local`, add an
HTTPRoute, and it resolves and terminates TLS with no further change.

## Part 4 — HTTPRoute over HTTPS: wildcard vs exact, chain-verified

The root CA is exported once so `curl --cacert` can verify against it:

```bash
kubectl -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > root-ca.crt
```

(Captured at the pre-Part-7b address `.202`; today the Gateway is `.240` — `scripts/check-routes.sh`
reads the address live and repeats this test, see Part 10.)

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
curl --cacert root-ca.crt --resolve nobody.example.test:443:172.18.255.240 https://nobody.example.test/
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
  -plaintext -authority grpc.poc.local 172.18.255.240:80 grpc.health.v1.Health/Check
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
  -cacert /certs/root-ca.crt -authority grpc.poc.local 172.18.255.240:443 grpc.health.v1.Health/Check
```

```
{
  "status": "SERVING"
}
```

And because the route also forwards the reflection service, a client can discover the API with no
`.proto`:

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest -plaintext -authority grpc.poc.local 172.18.255.240:80 list
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

### Part 5b — what `grpcurl` could not see: the listener offered no ALPN (gotcha #33)

The TLS result above is real and it is also misleading. `grpcurl` v1.9.3 is built on a grpc-go
older than 1.67, from before the client library started **enforcing** that a TLS server selects
`h2` via ALPN. A client on current grpc-go (1.76, the native client in Part 11) fails the same
call:

```
transport: authentication handshake failed: credentials: cannot check peer: missing selected ALPN property
```

Measured on the Gateway, before the fix:

```bash
echo | openssl s_client -connect 172.18.255.240:443 -servername grpc.poc.local -alpn h2,http/1.1 2>/dev/null | grep ALPN
```

```
No ALPN negotiated
```

Cilium ships ALPN off on Gateway listeners. Enable it, and **restart the operator** — the upgrade
only changes the ConfigMap, the operator reads it at startup, and `rollout status` will claim
success without any pod having restarted:

```bash
helm upgrade cilium cilium/cilium -n kube-system --version 1.20.1 --reuse-values --set gatewayAPI.enableAlpn=true
kubectl -n kube-system rollout restart deploy/cilium-operator
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=180s
kubectl -n routes get ciliumenvoyconfig -o yaml | grep -A1 alpnProtocols
```

```
              alpnProtocols:
              - h2,http/1.1
```

```bash
for s in grpc.poc.local web.poc.local exact.example.test; do printf '%-20s ' $s; echo | openssl s_client -connect 172.18.255.240:443 -servername $s -alpn h2,http/1.1 2>/dev/null | grep ALPN; done
```

```
grpc.poc.local       ALPN protocol: h2
web.poc.local        ALPN protocol: h2
exact.example.test   ALPN protocol: h2
```

The `grpc` Service already declares `appProtocol: kubernetes.io/h2c` (02-apps.yaml), which the
chart requires once ALPN is on so Envoy speaks h2c to that backend; `web` is HTTP/1.1 and needs
nothing. `scripts/check-routes.sh` re-run after the change: **0 failures** — HTTP/1.1, h2c and TCP
clients are unaffected. Full transcript: `output/client-check.txt`.

## Part 6 — TCPRoute, and the CRD-discovery gotcha

Raw TCP has no hostname, no path and no method, so a `TCPRoute` binds to its listener **by name**:

```yaml
spec:
  parentRefs:
    - name: routes-gw
      sectionName: tcp-echo
```

```bash
(echo "ping from the laptop"; sleep 1) | nc -w 5 172.18.255.240 9000
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

## Part 7 — Hubble UI on a real name, over TLS, across a namespace boundary

Demo 01 reached Hubble at a bare LoadBalancer address over plain HTTP. `04-hubble-via-gateway.yaml`
puts it at **`https://hubble.poc.local`** — with no change to Hubble and **no new certificate**,
because the name is under `*.poc.local` and the wildcard listener already covers it.

The interesting part is that the Gateway lives in `routes` and `hubble-ui` lives in `kube-system`.
Gateway API **refuses cross-namespace backends by default** — otherwise any team could route
traffic into any other team's Services. The demo shows the refusal first, on purpose:

```bash
# route only, no grant
kubectl -n routes get httproute hubble -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'
```

```
Accepted=True reason=Accepted
ResolvedRefs=False reason=RefNotPermitted
curl -> [http=500]
```

**Read that carefully: `Accepted=True` and a 500.** The route is valid and attached; the *backend
reference* is what was refused. A 500 from the Gateway with `RefNotPermitted` in the route status is
a consent gate, not a broken backend — and it is the first thing to check when a cross-namespace
route "works" in one cluster and 500s in another.

The consent is a `ReferenceGrant`, created **in the target namespace by its owner**, naming exactly
which Service may be referenced:

```yaml
kind: ReferenceGrant
metadata: {name: allow-routes-to-hubble-ui, namespace: kube-system}
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: routes}]
  to:   [{group: "", kind: Service, name: hubble-ui}]
```

```
Accepted=True reason=Accepted
ResolvedRefs=True reason=ResolvedRefs
curl -> [http=200 chain-verified]
```

And the certificate the Gateway presented for the new name — the wildcard, from the enterprise root:

```
X509v3 Subject Alternative Name: DNS:*.poc.local
issuer=CN=clustermesh-root-ca
```

## Part 7b — the Gateway range is reserved, not incidental

Until this point the wildcard pointed at whatever address the Gateway happened to get. That is
fragile in exactly the way gotcha #13 describes, and it also blurs an operational line: the
address DNS points at, a firewall names and a bookmark holds should be *a Gateway address by
construction*, not by allocation order.

`cilium/lb-ippool-poc1.yaml` now defines **two pools with complementary selectors** on the label Cilium
puts on every Gateway-generated Service, `io.cilium.gateway/owning-gateway`:

| Pool | Range | Selector | Draws from it |
|---|---|---|---|
| `gateway-pool` | `172.18.255.240–250` | label **Exists** | only Gateway-owned Services |
| `kind-docker-pool` | `172.18.255.200–239` | label **DoesNotExist** | everything else (hubble-ui is `.201`) |

Every Service matches exactly one pool. The ranges are disjoint because, per the
[LB IPAM docs](https://docs.cilium.io/en/stable/network/lb-ipam/), *"the last added pool will be
marked as Conflicting"* if they overlap — so the old single pool was shrunk in the **same apply**
that added the new one.

```
NAME               START            STOP             CONFLICT   AVAIL
gateway-pool       172.18.255.240   172.18.255.250   False      9
kind-docker-pool   172.18.255.200   172.18.255.239   False      39
```

Each Gateway is pinned **inside** its pool via `spec.infrastructure.annotations` — the path Cilium
actually propagates (the earlier `metadata` pin provably did not; see gotcha #13):

```
NS        NAME                        IP               PIN              GW-LABEL
default   cilium-gateway-sw-gateway   172.18.255.241   172.18.255.241   sw-gateway
routes    cilium-gateway-routes-gw    172.18.255.240   172.18.255.240   routes-gw
kube-system  hubble-ui                172.18.255.201   172.18.255.201   <none>
```

`PIN` is read from the **generated** Service, not from the Gateway — that is the check that was
missing before.

## Part 8 — DNS for a browser: the hosts block, generated from live state

`/etc/hosts` cannot express a wildcard, so every name is listed — and rather than copying addresses
from this README (which is how they go stale), `scripts/hosts-entries.sh` reads them from the
cluster:

```bash
scripts/hosts-entries.sh
```

```
# ---- cilium-kind-poc (generated 2026-09-11T17:31Z by scripts/hosts-entries.sh) ----
172.18.255.240  hubble.poc.local web.poc.local anything-at-all.poc.local grpc.poc.local exact.example.test
172.18.255.241  deathstar.poc.local
172.18.255.201  hubble-direct.poc.local
# ---- end cilium-kind-poc ----
```

(`.240` and `.241` are in `gateway-pool`, `.201` in `kind-docker-pool` — see NETWORKING_DESIGN §0.)

The script **never writes to `/etc/hosts` itself**. Review the block, then add it — this needs
`sudo`, so run it in a real Terminal. Either form works; they differ in *who runs the script*:

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc
sudo sh -c 'scripts/hosts-entries.sh >> /etc/hosts'      # script AND its kubectl run as root
#   works because macOS sudo keeps HOME (env_keep), so root reads your ~/.kube/config
scripts/hosts-entries.sh | sudo tee -a /etc/hosts        # script runs as you; only the write is root
```

Whichever you ran, count the names that landed — anything less than 3 lines means the script
could not reach the cluster (its warnings go to stderr, never into the file), and the block is
empty:

```bash
grep -c 'poc.local' /etc/hosts
```

```
3
```

Then verify the name resolves and the URL answers, in that order — each step isolates one layer:

```bash
dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # 1. drop the macOS resolver cache (killall needs sudo)
dscacheutil -q host -a name hubble.poc.local               # 2. the resolver sees the hosts entry
curl -s --cacert docs/root-ca.crt -o /dev/null -w '%{http_code}\n' https://hubble.poc.local/   # 3. TLS + route
open https://hubble.poc.local                              # 4. the browser
```

```
name: hubble.poc.local
ip_address: 172.18.255.240
200
```

If step 2 prints nothing, the hosts line is missing (or cached — redo step 1). If step 2 is right
and step 3 is `000`, the name is fine and the *route* is missing — SETUP 3.5 / NETWORKING_DESIGN
§4.3. If step 3 is `200` and the browser still warns, that is trust, not networking — next
paragraph.

To remove the block later: `sudo sed -i '' '/---- cilium-kind-poc/,/---- end cilium-kind-poc/d' /etc/hosts`.

**Trust the root once**, so the browser shows a padlock instead of a warning. The public
certificate is committed at `docs/root-ca.crt` (certificate only — the key never leaves the
cluster):

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain docs/root-ca.crt
```

Then, in a browser:

| URL | Serves | Via |
|---|---|---|
| https://hubble.poc.local | Hubble UI | Gateway, wildcard cert, ReferenceGrant |
| https://web.poc.local | demo app (`web`) | Gateway, wildcard cert |
| https://anything-at-all.poc.local | demo app | Gateway, wildcard cert — a name with no cert of its own |
| https://exact.example.test | demo app | Gateway, single-name cert |
| http://hubble-direct.poc.local | Hubble UI | the LoadBalancer directly, no TLS (demo 01 path) |

Both routing prerequisites still apply: `kernelForUDP` (SETUP 2.3b) and the host route (SETUP 3.5).
Without them the names resolve but nothing answers — and the diagnosis is the same as gotcha #3.
For what that route turns your Mac into — a router with the Docker VM as next hop and a Cilium node
answering ARP on the far side, shown with `traceroute` — see SETUP 3.5, *"What the route actually
makes your Mac"*.

## Part 9 — the wildcard *name*: dnsmasq

`/etc/hosts` gives you the five names above and nothing else. For `*.poc.local` to resolve — so a
new HTTPRoute for `foo.poc.local` works with **no hosts edit** — you need a resolver that answers
the whole domain. See Part 3c for the dnsmasq setup (`address=/.poc.local/172.18.255.240` plus
`/etc/resolver/poc.local`). That is the pairing that makes the wildcard *certificate* and a
wildcard *name* meet.

## Part 10 — re-checking access from outside, scripted (2026-09-11)

Everything above was captured while the demo was built. `scripts/check-routes.sh` re-proves it from
the laptop in one run — every route kind, both TLS listeners, the negative case, and Hubble UI
through the Gateway — and exits with the number of failed checks. It pins names with
`curl --resolve`, so it needs **no `/etc/hosts` entries**; the transcript is
`output/access-check.txt`.

```bash
scripts/record.sh demos/09-routes/output/access-check.txt scripts/check-routes.sh
```

```
Gateway routes-gw address: 172.18.255.240   (must be inside gateway-pool 172.18.255.240-250)
KIND        NAME       HOSTS                         ACCEPTED   RESOLVED
HTTPRoute   anything   [anything-at-all.poc.local]   True       True
HTTPRoute   exact      [exact.example.test]          True       True
HTTPRoute   hubble     [hubble.poc.local]            True       True
HTTPRoute   web        [web.poc.local]               True       True
GRPCRoute   grpc       [grpc.poc.local]              True       True
TCPRoute    echo       <none>                        True       True

1. HTTPRoute x3 over HTTPS, certificate chain verified against the enterprise root (docs/root-ca.crt)
  PASS  https://web.poc.local/ (wildcard listener, *.poc.local cert) -> 200
  PASS  https://anything-at-all.poc.local/ (wildcard listener, *.poc.local cert) -> 200
  PASS  https://exact.example.test/ (exact listener, its own cert) -> 200
  PASS  https://nobody.poc.local/ (under the wildcard but NO route -> Gateway 404) -> 404
   SNI -> certificate presented:
     web.poc.local        DNS:*.poc.local
     exact.example.test   DNS:exact.example.test

2. HTTPRoute over plain HTTP :80 (Host header selects the route)
  PASS  http://172.18.255.240/ Host: web.poc.local -> 200

3. GRPCRoute (grpcurl runs in a container on the docker network; -authority is the route's hostname)
  PASS  h2c :80 Health/Check -> {"status":"SERVING"}
  PASS  TLS :443 Health/Check, wildcard cert verified -> {"status":"SERVING"}

4. TCPRoute :9000 (bytes in, bytes back — no HTTP involved)
  PASS  tcp echo -> hello from echo (tcp echo)|echo echoed: ping from check-routes|

5. Hubble UI through the SAME Gateway URL: https://hubble.poc.local (HTTPRoute in routes -> Service in kube-system via ReferenceGrant)
  PASS  https://hubble.poc.local/ (index) -> 200
  PASS  page title <title>Hubble UI</title>
  PASS  asset /bundle.main.811eb2d9fcafb97bbf36.js -> 200
  PASS  asset /bundle.main.0f16d72c3dee99c3b95a.css -> 200
  PASS  same UI direct at its own LB address (kind-docker-pool) for comparison -> 200
   Hubble's own view of that request (world -> hubble-ui, through the Gateway):
     Sep 11 17:14:43.240: 10.10.4.35:52729 (world) -> kube-system/hubble-ui-778c684b94-xmp6n:8081 (ID:73875) to-overlay FORWARDED (TCP Flags: ACK, FIN)

FAILED CHECKS: 0
```

**What the Hubble check does and does not prove.** It proves the page, its 1.7 MB JS bundle and
its CSS are served through the Gateway with the wildcard certificate, and that the request arrives
at the `hubble-ui` pod as identity `world` (it entered from outside). The UI's *data* channel is a
grpc-web stream under `/api/` that only the browser's bundle opens; a hand-made `POST
/api/ui.UI/GetControlStream` returns the backend's `404 page not found` **identically** via the
Gateway (as `grpc-status: 12`, `server: envoy`) and via the direct address — which shows the Gateway
is transparent to it, not that the stream works. The last step is the browser: add the hosts line
and open the URL — the service map must fill.

**Browser-verified 2026-09-11 19:13 UTC.** With the hosts line in place and the UI open in Safari,
the relay shows the browser's own data calls arriving through the Gateway — and it names the real
paths, which are not `ui.UI/…` at all:

```
19:13:32.171: 192.168.64.1:57806 (ingress) -> kube-system/hubble-ui-…:8081 http-request  FORWARDED (HTTP/1.1 POST http://hubble.poc.local/api/control-stream)
19:13:32.173: 192.168.64.1:57806 (ingress) <- kube-system/hubble-ui-…:8081 http-response FORWARDED (HTTP/1.1 200 3ms  (POST http://hubble.poc.local/api/control-stream))
19:13:33.184: 192.168.64.1:57806 (ingress) -> kube-system/hubble-ui-…:8081 http-request  FORWARDED (HTTP/1.1 POST http://hubble.poc.local/api/service-map-stream)
19:13:33.198: 192.168.64.1:57806 (ingress) <- kube-system/hubble-ui-…:8081 http-response FORWARDED (HTTP/1.1 200 14ms (POST http://hubble.poc.local/api/service-map-stream))
```

`192.168.64.1` is the Mac's address on `bridge100` (NETWORKING_DESIGN §2) and `ingress` is the
Gateway's identity — the whole path of §4.4, seen by Hubble from the inside.

```bash
scripts/hosts-entries.sh            # prints; you append it yourself
sudo sh -c 'scripts/hosts-entries.sh >> /etc/hosts'
open https://hubble.poc.local       # macOS; trust docs/root-ca.crt in Keychain first, or click through
```

## Part 11 — one native client for all three routes (no Docker, no grpcurl)

`grpcurl` needed a container and the TCP test needed `nc`. The demo app now has a fourth mode,
`-mode client`, in the same `app/main.go`: it speaks HTTPS with the enterprise root, gRPC over
h2c **and** over TLS with SNI, and the raw TCP echo — pinning every hostname to the Gateway
address in code the way `curl --resolve` does, so it needs **no `/etc/hosts`**. It exits with the
number of failed checks. Build it for the machine you are on (Go 1.24+):

```bash
cd demos/09-routes/app
go build -o routedemo .                                   # this machine (macOS here)
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o routedemo-linux .   # for a Linux server
```

Run it from **wherever you are** — the default `-ca docs/root-ca.crt` is found by walking up from
the current directory to the repo root, so both of these work:

```bash
./routedemo -mode client -target 172.18.255.240                          # still in demos/09-routes/app
demos/09-routes/app/routedemo -mode client -target 172.18.255.240        # from the repo root
```

```
2026/09/11 14:28:58 using CA /Users/olasumbo/gitRepos/cilium-kind-poc/docs/root-ca.crt (found by walking up from the current directory)
```

Outside the repo, or with a wrong path, it fails loudly and says what to pass:

```
read CA docs/root-ca.crt: open docs/root-ca.crt: no such file or directory
  pass -ca <path to docs/root-ca.crt>; from demos/09-routes/app that is -ca ../../../docs/root-ca.crt
```

Read the Gateway address live rather than typing it, if you prefer:
`-target "$(kubectl -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')"`.

To test one route type only — the gRPC question on its own, for example — add `-only`:

```bash
./routedemo -mode client -only grpc -target 172.18.255.240        # from demos/09-routes/app; the CA is found automatically
```

```
3. GRPCRoute -- grpc.health.v1.Health/Check, over h2c (:80) and over TLS (:443)
  PASS  h2c  grpc.poc.local:80   SERVING
  PASS  TLS  grpc.poc.local:443  SERVING

FAILED CHECKS: 0
```

`-only http` and `-only tcp` do the same for the other two; the exit code is still the number of
failed checks in what ran. Both, as run by the operator from `demos/09-routes/app` on 2026-09-11
(with the explicit `-ca ../../../docs/root-ca.crt`, before the CA lookup above existed):

```
macbookpro:app olasumbo$ ./routedemo -mode client -only http -target 172.18.255.240 -ca ../../../docs/root-ca.crt
Gateway 172.18.255.240, root CA ../../../docs/root-ca.crt, wildcard domain *.poc.local, exact host exact.example.test

1. HTTPRoute over HTTPS -- chain verified against the root, SNI selects the listener
  PASS  https://web.poc.local/  200, app echoed host and tls=true
  PASS  https://anything-at-all.poc.local/  200, app echoed host and tls=true
  PASS  https://exact.example.test/  200, app echoed host and tls=true
  PASS  https://nobody.poc.local/  404 -- wildcard cert served it, no HTTPRoute claimed it
  PASS  https://nobody.example.test/  TLS refused as expected: connection reset by peer

2. HTTPRoute over plain HTTP :80 -- the Host header picks the route
  PASS  http://172.18.255.240/ Host: web.poc.local  200

FAILED CHECKS: 0
```

```
macbookpro:app olasumbo$ ./routedemo -mode client -only tcp -target 172.18.255.240 -ca ../../../docs/root-ca.crt
Gateway 172.18.255.240, root CA ../../../docs/root-ca.crt, wildcard domain *.poc.local, exact host exact.example.test

4. TCPRoute :9000 -- greeting on connect, then a line echoed back
  PASS  tcp  greeting "hello from echo (tcp echo)" then "echo echoed: ping from routedemo client"

FAILED CHECKS: 0
```

Recorded run (`output/client-check.txt`, after Part 5b's ALPN fix):

```
Gateway 172.18.255.240, root CA docs/root-ca.crt, wildcard domain *.poc.local, exact host exact.example.test

1. HTTPRoute over HTTPS -- chain verified against the root, SNI selects the listener
  PASS  https://web.poc.local/  200, app echoed host and tls=true
  PASS  https://anything-at-all.poc.local/  200, app echoed host and tls=true
  PASS  https://exact.example.test/  200, app echoed host and tls=true
  PASS  https://nobody.poc.local/  404 -- wildcard cert served it, no HTTPRoute claimed it
  PASS  https://nobody.example.test/  TLS refused as expected: connection reset by peer

2. HTTPRoute over plain HTTP :80 -- the Host header picks the route
  PASS  http://172.18.255.240/ Host: web.poc.local  200

3. GRPCRoute -- grpc.health.v1.Health/Check, over h2c (:80) and over TLS (:443)
  PASS  h2c  grpc.poc.local:80   SERVING
  PASS  TLS  grpc.poc.local:443  SERVING

4. TCPRoute :9000 -- greeting on connect, then a line echoed back
  PASS  tcp  greeting "hello from echo (tcp echo)" then "echo echoed: ping from routedemo client"

FAILED CHECKS: 0
```

### Validate the client yourself — step by step

Each step isolates one behaviour and states the exact expected output; a wrong result in step 2
almost always means step 1 was skipped.

**1. Rebuild from the fixed source** (a binary built before commit `b44d5d7` has none of this):

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc/demos/09-routes/app
git log --oneline -1 -- main.go        # b44d5d7 or later
go build -o routedemo .
ls -l routedemo                        # timestamp must be now
```

**2. From `app/`, no `-ca` — the default is found by walking up:**

```bash
./routedemo -mode client -only grpc -target 172.18.255.240
```

```
2026/09/11 15:44:18 using CA /Users/olasumbo/gitRepos/cilium-kind-poc/docs/root-ca.crt (found by walking up from the current directory)
3. GRPCRoute -- grpc.health.v1.Health/Check, over h2c (:80) and over TLS (:443)
  PASS  h2c  grpc.poc.local:80   SERVING
  PASS  TLS  grpc.poc.local:443  SERVING

FAILED CHECKS: 0
```

**3. From the repo root — the path exists as given, so no `using CA` line:**

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc
demos/09-routes/app/routedemo -mode client -only grpc -target 172.18.255.240; echo "exit=$?"   # exit=0
```

**4. Outside the repo — must fail and say what to pass:**

```bash
cd /tmp && /Users/olasumbo/gitRepos/cilium-kind-poc/demos/09-routes/app/routedemo -mode client -only grpc -target 172.18.255.240; echo "exit=$?"
```

```
read CA docs/root-ca.crt: open docs/root-ca.crt: no such file or directory
  pass -ca <path to docs/root-ca.crt>; from demos/09-routes/app that is -ca ../../../docs/root-ca.crt
exit=1
```

**5. A wrong explicit path is never "fixed" — you typed it, so it is your intent:**

```bash
cd /Users/olasumbo/gitRepos/cilium-kind-poc/demos/09-routes/app
./routedemo -mode client -only grpc -target 172.18.255.240 -ca nope.crt; echo "exit=$?"     # same error + hint, exit=1
```

**6. `-only` — one route type at a time, and a bad value refused:**

```bash
./routedemo -mode client -only http  -target 172.18.255.240    # 6 PASS, FAILED CHECKS: 0
./routedemo -mode client -only tcp   -target 172.18.255.240    # 1 PASS, FAILED CHECKS: 0
./routedemo -mode client -only bogus -target 172.18.255.240; echo "exit=$?"
```

```
2026/09/11 15:44:18 unknown -only "bogus" (want http, grpc, tcp or all)
exit=1
```

**7. Everything, with the exit code as the gate:**

```bash
./routedemo -mode client -target 172.18.255.240 && echo ALL-GOOD     # 9 PASS, FAILED CHECKS: 0, ALL-GOOD
```

**8. Server and client are one binary — compare the image config digest, not the pod's `imageID`.**
A pod loaded with `kind load` reports `imageID: docker.io/library/import-2026-09-11@sha256:74295b…`,
the digest of the *import manifest*; the laptop's `docker image inspect` ID is the *config*
digest (`2bf472…`). They never match, by construction (gotcha #38). containerd's `id` is the
config digest, and that is the one to compare:

```bash
LOCAL=$(docker image inspect routedemo:local --format '{{.Id}}')
for n in poc1-control-plane poc1-control-plane2 poc1-control-plane3 poc1-worker poc1-worker2; do
  printf '%-22s ' $n
  id=$(docker exec $n crictl inspecti docker.io/library/routedemo:local | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')
  [ "$id" = "$LOCAL" ] && echo "same as laptop" || echo "DIFFERENT: $id"
done
```

```
poc1-control-plane     same as laptop
poc1-control-plane2    same as laptop
poc1-control-plane3    same as laptop
poc1-worker            same as laptop
poc1-worker2           same as laptop
```

Two proofs now exist for the same routes and they deliberately use different clients:
`scripts/check-routes.sh` (curl, a grpcurl container, `nc`) and this binary (Go stdlib TLS,
grpc-go 1.76). Their disagreement is what found gotcha #33. The image was rebuilt from the same
source (`routedemo:local`, 14.6 MB) and the three deployments rolled onto it, so the running
servers and the client are one binary.

## What to take away

| Claim | Evidence |
|---|---|
| cert-manager issues Gateway certs from one annotation | 2 certs `READY` in 5 s, both `issuer=CN=clustermesh-root-ca` |
| A wildcard cert covers names never configured | `anything-at-all.poc.local` → 200, chain-verified |
| An exact cert is exact | `nobody.example.test` → TLS failure, exit 35 |
| Two certs on one port | SNI selects `*.poc.local` vs `exact.example.test` on :443 |
| `HTTPRoute` | 3 hostnames → `web`, 200 over both HTTPS and HTTP |
| `GRPCRoute` | `Health/Check` → `SERVING` over h2c **and** TLS; reflection lists services |
| gRPC over TLS needs ALPN | `gatewayAPI.enableAlpn=true` **and** an operator restart; grpc-go ≥ 1.67 refuses a listener without `h2` (gotcha #33) |
| One native client, three protocols | `routedemo -mode client` — HTTPS, gRPC h2c + TLS, TCP echo; exit code = failed checks |
| `TCPRoute` | echo round-trip on :9000 |
| One image, three protocols | `routedemo:local`, 14 MB, `-mode http\|grpc\|tcp` |
| Cross-namespace backends need consent | `RefNotPermitted` → 500 until a `ReferenceGrant` in `kube-system`; then 200 |
| Hubble on a real TLS name | `https://hubble.poc.local`, wildcard cert, no change to Hubble |

## Clean up

```bash
kubectl delete -f demos/09-routes/03-routes.yaml -f demos/09-routes/02-apps.yaml -f demos/09-routes/01-gateway.yaml
```

## Evidence

Captured 2026-09-12 with `scripts/evidence/capture.js` and `scripts/evidence/collect.sh` (both re-runnable; the pod and Cilium output is the recorded file [`output/evidence.txt`](output/evidence.txt)). Every image is what the browser saw, with traffic running.

**web poc local** — the wildcard HTTPS route

![web-poc-local](output/screenshots/web-poc-local.png)

**exact example test** — the exact-hostname listener with its own certificate, the one host the wildcard does not cover

![exact-example-test](output/screenshots/exact-example-test.png)

**bank api poc local** — a second route to the bank API on its own hostname

![bank-api-poc-local](output/screenshots/bank-api-poc-local.png)

**Running pods** (from `output/evidence.txt`):

```console
$ kubectl --context kind-poc1 -n routes get pods -o wide
NAME                    READY   STATUS    RESTARTS   AGE   IP            NODE           NOMINATED NODE   READINESS GATES
echo-5dd4997b94-4vg4k   1/1     Running   0          9h    10.10.4.207   poc1-worker    <none>           <none>
echo-5dd4997b94-b2s9s   1/1     Running   0          9h    10.10.3.136   poc1-worker2   <none>           <none>
grpc-57c4b8cdf5-8fpgv   1/1     Running   0          9h    10.10.3.97    poc1-worker2   <none>           <none>
grpc-57c4b8cdf5-l9gfj   1/1     Running   0          9h    10.10.4.177   poc1-worker    <none>           <none>
web-775dfff659-hgw8w    1/1     Running   0          9h    10.10.3.8     poc1-worker2   <none>           <none>
web-775dfff659-ndjw7    1/1     Running   0          9h    10.10.4.235   poc1-worker    <none>           <none>
```

The Cilium/kubectl commands that prove this demo's claim, with their output, follow the pod listings in [`output/evidence.txt`](output/evidence.txt).
