# Demo 53 — four things to try

Four read-only exercises against the demo once it is up; nothing here
changes the cluster.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- `grpcurl` runs in a container on the `kind` network (it is not
  installed on this Mac).
- The live root `.tmp/root-ca.crt` for the TLS call in exercise 3.

## Exercises

### 1. Call a method the route does not match

The route matches `grpc.health.v1.Health` and both reflection services
only. `routedemo.Echo` is a health status name, not a reflected service.
A matched service with a missing method (`grpc.health.v1.Health/NoSuchMethod`)
answers `does not include a method named "NoSuchMethod"` — Envoy
forwarded it; the backend answered.

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 routedemo.Echo/DoesNotExist
```

**Expect:** grpcurl asks reflection (which is matched) for a descriptor,
then the backend says the service is not there — not an Envoy 404.

```text
Error invoking method "routedemo.Echo/DoesNotExist": target server does not expose service "routedemo.Echo"
```

### 2. Call with the wrong `:authority`

No GRPCRoute hostname matches `wrong.poc.local`, so reflection is not
forwarded. That is Cilium's Envoy for "this Host is not gRPC" on the
hostname-less `:80` listener. An HTTP/1.1 GET with
`Host: grpc.poc2.shop.poc.local` on the same port is Envoy's 404 (gRPC
is not HTTP/1.1); `Host: api.poc2.shop.poc.local` there is demo 41's 301.

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority wrong.poc.local \
  172.18.255.177:80 grpc.health.v1.Health/Check
```

**Expect:** the sentence below (not in this demo's transcript — `apply.sh`
records only the unmatched-method probe; the same sentence is recorded
from Envoy Gateway in demo 54's transcript).

```text
Error invoking method "grpc.health.v1.Health/Check": failed to query for service descriptor "grpc.health.v1.Health": server does not support the reflection API
```

### 3. List services through reflection

No `.proto` file. `routedemo.Echo` does not appear. Repeat with TLS
(`-cacert` the live root, `:443`) against the same authority;
Health/Check is `SERVING`.

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 list
```

**Expect:** Health and both reflection services (identical on poc1 at
`.240` with `-authority grpc.poc.local`).

```text
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
```

### 4. Run the check

```bash
demos/53-grpc-parity/check.sh
```

**Expect:** 10 PASS, 0 FAIL, 1 WARN (11 rows). The WARN is the missing
Mac binary.

```text
  WARN   Mac grpcurl (not installed)                                            command -v grpcurl: not found                        skip: brew install grpcurl, then grpcurl -plaintext -authority grpc.poc2.shop.poc.local 172.18.255.177:80 grpc.health.v1.Health/Check
```

## Clean up

[README Clean up](README.md#clean-up).
