# Demo 52 — six things to try

Six exercises against the demo once it is up; nothing here changes the cluster except the hosts block under Prerequisites.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- The Mac has a route to `172.19/16` ([gotcha #120](../../docs/GOTCHAS.md#120)).
- Go is installed so grpcurl v1.9.4 runs.
- The hosts block — the one sudo step (the script only prints the lines; the `tee` writes them):

```bash
demos/52-eg-poc2-metallb/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Exercises

### 1. Open the orders page in the browser

The HTTP door's `:80` has a hostname and no redirect, so the real browser
opens the shop's `/orders` page over plain http.

```bash
open http://api.eg-poc2.poc.local/orders
```

**Expect:** the three recorded rows (`keyboard` 4999 ¢, `mouse` 1999 ¢,
`monitor` 24900 ¢). apply.sh already wrote the same URL to
`output/browser.png` (`1000 x 500`, `chrome_rc=0`).

```text
screenshot written after 2.0 s; chrome_rc=0
demos/52-eg-poc2-metallb/output/browser.png: PNG image data, 1000 x 500, 8-bit/color RGB, non-interlaced
```

![the orders page](output/browser.png)

### 2. Call the HTTP door with curl

http, then https with `--cacert` against `.tmp/eg-poc2-root-ca.crt` (no skip
of verification).

```bash
curl -s --resolve api.eg-poc2.poc.local:80:172.19.255.150 \
  -D - -o /dev/null http://api.eg-poc2.poc.local/healthz

curl -s --resolve api.eg-poc2.poc.local:443:172.19.255.150 \
  --cacert .tmp/eg-poc2-root-ca.crt \
  -D - -o /dev/null https://api.eg-poc2.poc.local/healthz
```

**Expect:** the recorded header lines.

```text
http://api.eg-poc2.poc.local/healthz @ 172.19.255.150:80 → 200 X-Served-By=eg-poc2 curl_rc=0
https://api.eg-poc2.poc.local/healthz @ 172.19.255.150:443 → 200 X-Served-By=eg-poc2 curl_rc=0
```

### 3. Route gRPC by method and by metadata

ListOrders is the service default (`v1`). GetOrder is a method match
(`v2`). The same ListOrders with header `x-version: v2` is a metadata
match (`v2`).

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  -d '{"id":2}' 172.19.255.151:80 shop.v1.Orders/GetOrder

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  -H 'x-version: v2' \
  172.19.255.151:80 shop.v1.Orders/ListOrders
```

**Expect:** the recorded T2 / T4 / T5 lines.

```text
T T2 expected=3 orders version v1 served_by grpcdemo-v1- observed=v1 + three rows PASS
T T4 expected=GetOrder id=2 version v2 observed=v2 PASS
T T5 expected=x-version v2 then default v1 observed=v2 then v1 PASS
```

### 4. Try the wrong door

grpcurl at `.150` with the gRPC authority, then curl of the API host at
`.151`. Neither Gateway has a route for the other protocol.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.150:80 grpc.health.v1.Health/Check

curl -s --resolve api.eg-poc2.poc.local:80:172.19.255.151 \
  -o /dev/null -w '%{http_code}\n' http://api.eg-poc2.poc.local/healthz
```

**Expect:** the recorded exit 1 and 404.

```text
Error invoking method "grpc.health.v1.Health/Check": failed to query for service descriptor "grpc.health.v1.Health": server does not support the reflection API
exit status 1
isolation_grpcurl_rc=1
isolation_http_code=404 curl_rc=0
```

### 5. Call a method the server does not have

Reflection-driven grpcurl validates the method locally, so an
unimplemented method must be described to it to be sent at all. The
first descriptor names a missing method on the routed `Orders` service;
the second names a service no `GRPCRoute` rule matches.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -import-path demos/52-eg-poc2-metallb/probe -proto probe.proto \
  -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/NoSuchMethod

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -import-path demos/52-eg-poc2-metallb/probe -proto nope.proto \
  -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Nope/Do
```

**Expect:** the recorded T8a / T8b bodies.

```text
ERROR:
  Code: Unimplemented
  Message: unknown method NoSuchMethod for service shop.v1.Orders
exit status 76
T T8a expected=Code: Unimplemented + unknown method observed=Unimplemented unknown method PASS
ERROR:
  Code: Unimplemented
  Message: 
exit status 76
T T8b expected=Code: Unimplemented + empty Message observed=Unimplemented empty Message PASS
```

### 6. Run the check

```bash
demos/52-eg-poc2-metallb/check.sh
```

**Expect:** the recorded summary line.

```text
demo 52 check: 0 FAIL
```

## Clean up

[README Clean up](README.md#clean-up).
