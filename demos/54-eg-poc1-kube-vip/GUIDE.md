# Demo 54 — five things to try

Five exercises against the demo once it is up; nothing here changes the cluster except the hosts block under Prerequisites.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- The Mac has a route to `172.19/16` ([gotcha #120](../../docs/GOTCHAS.md#120)).
- Go is installed so grpcurl v1.9.4 runs (recorded: Go `1.27.1`).
- The hosts block — the one sudo step (the script only prints the lines; the `tee` writes them):

```bash
demos/54-eg-poc1-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Exercises

### 1. Open the orders page in the browser

The HTTP door's `:80` has a hostname and no redirect, so the real browser
opens the shop's `/orders` page over plain http.

```bash
open http://api.eg-poc1.poc.local/orders
```

**Expect:** the three recorded rows (`keyboard` 4999 ¢, `mouse` 1999 ¢,
`monitor` 24900 ¢). apply.sh already wrote the same URL to
`output/browser.png` (`1000 x 500`, `chrome_rc=0`).

![the orders page](output/browser.png)

### 2. Call the HTTP door with curl

http, then https with `--cacert` against `.tmp/eg-poc1-root-ca.crt` (no skip
of verification).

```bash
curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.100 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz

curl -s --resolve api.eg-poc1.poc.local:443:172.19.255.100 \
  --cacert .tmp/eg-poc1-root-ca.crt \
  -D - -o /dev/null https://api.eg-poc1.poc.local/healthz
```

**Expect:** the recorded header lines.

```text
http://api.eg-poc1.poc.local/healthz @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0
https://api.eg-poc1.poc.local/healthz @ 172.19.255.100:443 → 200 X-Served-By=eg-poc1 curl_rc=0
```

### 3. Call the gRPC door with grpcurl

h2c on `:80`, TLS on `:443`, then `list`. The `:authority` is
`grpc.eg-poc1.poc.local`.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 grpc.health.v1.Health/Check

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -cacert .tmp/eg-poc1-root-ca.crt -authority grpc.eg-poc1.poc.local \
  172.19.255.101:443 grpc.health.v1.Health/Check

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 list
```

**Expect:** the recorded SERVING bodies and the three listed services.

```text
{
  "status": "SERVING"
}
grpcurl_h2c_rc=0
{
  "status": "SERVING"
}
grpcurl_tls_rc=0
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
grpcurl_list_rc=0
```

### 4. Try the wrong door

grpcurl at `.100` with the gRPC authority, then curl of the API host at
`.101`. Neither Gateway has a route for the other protocol.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.100:80 grpc.health.v1.Health/Check

curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.101 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz
```

**Expect:** the recorded exit 1 and 404.

```text
Error invoking method "grpc.health.v1.Health/Check": failed to query for service descriptor "grpc.health.v1.Health": server does not support the reflection API
exit status 1
isolation_grpcurl_rc=1
isolation_http_code=404 curl_rc=0
```

### 5. Run the check

```bash
demos/54-eg-poc1-kube-vip/check.sh
```

**Expect:** the recorded summary line.

```text
demo 54 check: 0 FAIL
```

## Clean up

[README Clean up](README.md#clean-up).
