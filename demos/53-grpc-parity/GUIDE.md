# Demo 53 — the guide: exercises

Run from the repo root with poc1 and poc2 up and demo 53 applied
(`demos/53-grpc-parity/apply.sh`). Exercise 0 is `apply.sh` itself. `grpcurl` runs in a
container on the `kind` network (it is not installed on this Mac; `brew install grpcurl` to
do these without Docker).

## Exercise 1 — call a method the route does not match

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 routedemo.Echo/DoesNotExist
```

*Expect (measured 2026-09-18):*

```text
Error invoking method "routedemo.Echo/DoesNotExist": target server does not expose service "routedemo.Echo"
```

The route matches `grpc.health.v1.Health` and both reflection services only.
`routedemo.Echo` is a health **status name** in the app, not a reflected service. grpcurl
asks reflection (which **is** matched) for a descriptor, then the backend says the service
is not there. That is not an Envoy 404. `foo.Bar/Baz` returns the same sentence.
`grpc.health.v1.Health/NoSuchMethod` (service matched, method not): `service
"grpc.health.v1.Health" does not include a method named "NoSuchMethod"`. Cilium's Envoy
forwarded those; it did not invent UNIMPLEMENTED itself.

## Exercise 2 — call with the wrong `:authority`

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority wrong.poc.local \
  172.18.255.177:80 grpc.health.v1.Health/Check
```

*Expect (measured 2026-09-18):*

```text
Error invoking method "grpc.health.v1.Health/Check": failed to query for service descriptor "grpc.health.v1.Health": server does not support the reflection API
```

No GRPCRoute hostname matches `wrong.poc.local`, so reflection is not forwarded. That is
Cilium's Envoy for "this Host is not gRPC" on the hostname-less `:80` listener. Contrast:
`Host: api.poc2.shop.poc.local` on the same port is still demo 41's HTTP 301; an HTTP GET
with `Host: grpc.poc2.shop.poc.local` is Envoy 404 (gRPC is not HTTP/1.1).

## Exercise 3 — list services through reflection

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 list
```

*Expect (measured 2026-09-18, identical on poc1 @ `.240` with `-authority grpc.poc.local`):*

```text
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
```

No `.proto` file. `routedemo.Echo` does **not** appear — it is not a registered gRPC
service. Repeat with TLS (`-cacert` the live root `.tmp/root-ca.crt`, `:443`) against the
same authority; `Health/Check` is `"status": "SERVING"`.

## Cleanup

`demos/53-grpc-parity/cleanup.sh` — route, app, CNP, `grpc-tls`. The `https-grpc` listener
stays (demo 40's door).
