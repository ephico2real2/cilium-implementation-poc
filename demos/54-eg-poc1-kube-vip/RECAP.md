# What demo 54 did — the walk-through

**The goal** — Enhancement 007 builds a second lab next to the Cilium one so a
reader can name every part Cilium had bundled. Demo 50 poured the slab on
two clusters. Demo 51 hung kube-vip on both and proved the fail cases.
Demo 54 is the one-cluster picture: one kind
cluster (`eg-poc1`), default CNI, kube-vip, and Envoy Gateway API,
with HTTP and gRPC through two Gateways, reachable from the
MacBook — curl, grpcurl, and the browser. The fail cases stay in demo 51.

**1. The guide grew a one-cluster lab.**
`scripts/eg-up.sh` is now a function of the argument list. `eg-poc1`
alone is this lab: it mints its own root (D8 holds per lab), the
transcript lands here, and the PEM is `.tmp/eg-poc1-root-ca.crt`.
Mixing the two labs exits 2 before any work. The 2026-09-19T13:10:02Z
run installed the network, the cluster from `clusters/eg-poc1.yaml`
(control-plane plus worker, pod CIDR `10.70.0.0/16`, service CIDR
`10.71.0.0/16`), 10 Gateway API CRDs at `channel=standard`
`bundle-version=v1.6.2`, 8 `gateway.envoyproxy.io` CRDs via
`helm template | kubectl apply --server-side`, the controller
with `crds.enabled=false`, `GatewayClass eg` (`Accepted=True`),
cert-manager (`Available=True`), and the root
`91:84:DE:7D:65:FE:12:9A:35:23:0A:E1:17:24:BD:C3:E5:67:78:8E:56:34:A1:6A:64:6E:BB:1D:AF:7E:E3:81`.

**2. Two doors, not one, so HTTP and gRPC cannot share a hostname.**
A Gateway (Envoy Gateway's front door — its own Envoy Deployment and
Service, not a share of the node's proxy) does not pick an address by
existing. The `EnvoyProxy` attached to it, created in the same file and
before the Gateway, sets `envoyService.loadBalancerClass:
kube-vip.io/kube-vip-class` and pins the IP with
`kube-vip.io/loadbalancerIPs`. The class is immutable: attach later and
Envoy Gateway logs `may not change once set`. `http-gw` sits at
`172.19.255.100` with listeners `http :80` and `https :443`, both
hostname `api.eg-poc1.poc.local`. The `:80` listener has **no redirect**
— the browser works over plain http, which is the opposite of demo 51's
301 on purpose. `grpc-gw` sits at `172.19.255.101` with listeners
`h2c :80` and `https-grpc :443`, both hostname `grpc.eg-poc1.poc.local`.
An `HTTPRoute` attaches only to `http-gw`; a `GRPCRoute` attaches only
to `grpc-gw`. That is the isolation, measured on the third apply:
grpcurl against the HTTP door with the gRPC authority exited 1
(`server does not support the reflection API`); curl of `/healthz` at
the gRPC door with the API host returned `isolation_http_code=404`. Two
lines, not a test suite.

**3. kube-vip announces, and Docker can see it.**
The DaemonSet, cloud-provider and RBAC are the phase 0 files under
`clusters/eg/`; the ConfigMap gives the doors `.100–.110`. apply.sh records `arping -b -c 3` from `busybox:1.36` on
`kind-eg` (every probe a broadcast), maps the reply MAC to a node,
shows the `/32` on that node's `eth0`, and greps kube-vip for
`adding VIP` / `successful add IP`. arping got three replies from
`fa:1f:d6:0f:1e:ae` for each address — `eg-poc1-worker`. That node's `eth0` carries `172.19.0.3/16`
and both VIPs as `/32 scope global deprecated` with
`preferred_lft forever`. `deprecated` is kube-vip adding the address
with a zero preferred lifetime (v1.2.4 `pkg/vip/address.go:172-176`:
`PreferedLft = 0`, `ValidLft = math.MaxInt`). The kernel
(`net/ipv4/devinet.c` `set_ifa_lifetime`) turns that into
`IFA_F_DEPRECATED` plus `IFA_F_PERMANENT`, and `inet_fill_ifaddr`
reports both lifetimes as infinity, so `ip` prints `deprecated` with
`preferred_lft forever`. Both Envoy pods and the `envoy-gateway` pod
run on `eg-poc1-worker`, both door Services are
`externalTrafficPolicy: Local` (Envoy Gateway's default), and kube-vip
with `svc_election` elects only among nodes with a ready local
endpoint — the worker is the only candidate. The fourth apply's record shows all three phrases for both doors
(`adding VIP`, `successful add IP`, `layer 2 broadcaster starting`);
the 13:14:15 / 13:14:26 stamps are the first apply's, reprinted
by the whole-log read.

**4. What we did in Docker is part of the proof.**
The cluster sits on `kind-eg`: Docker allocates node addresses from
`172.19.0.0/17` only, so `172.19.255.0/24` can never be a node address. The third apply recorded IPv4 `Subnet=172.19.0.0/16`
`IPRange=172.19.0.0/17` `Gateway=172.19.0.1` (the IPv6 block's
`IPRange` prints `invalid Prefix` and is skipped), the two node
containers `eg-poc1-control-plane 172.19.0.2 e6:61:1d:ac:15:3a` and
`eg-poc1-worker 172.19.0.3 fa:1f:d6:0f:1e:ae` (both `Up About an hour`,
Ready at 67 m, v1.36.4), kube-proxy `mode: iptables`, and kindnet plus
kube-proxy DaemonSets 2/2. There is no Cilium — the check captures the
listings before it counts them (`cilium_ds=0 cilium_crd=0`), so a
kubectl that cannot reach the cluster is a FAIL and not "zero matches".

**5. The MacBook is a client on the same LAN.**
The Mac routes `172.19/16` to the Docker VM. apply.sh records
`netstat -rn | grep 172.19`; if the route is absent it prints the
`sudo route` command and continues — no script runs sudo. The first
apply, 2026-09-19T13:14Z, printed `no 172.19 route on this Mac` and
every Mac client failed (`curl_rc=28`, grpcurl deadline, Chrome wrote
nothing) while both Gateways were Programmed and each door had three
ARP replies — gotcha #120. The operator re-added `172.19.0.0/16` via
`192.168.64.2`. The third apply recorded
`172.19 192.168.64.2 UGSc bridge100`. From that route,
`curl --resolve` hit `/healthz` at `.100` and got 200 plus
`X-Served-By: eg-poc1` (from ConfigMap `eg-cluster`) on both `:80` and
`:443` (`--cacert .tmp/eg-poc1-root-ca.crt`, verification not skipped).
`/orders` is the page behind the door. shopapi's default `DB_URL`
(`main.go:56`, enhancement 002 R3) was the second apply's body
(`lookup db-service.poc.local`). `shop-db` is local to this demo
(`45-shop-db.yaml`, postgres:16-alpine, emptyDir). The third apply's
`/orders` was 200 with three rows: keyboard 4999 ¢, mouse 1999 ¢,
monitor 24900 ¢. `grpcurl` on the Mac against `.101:80` and `.101:443`
both returned `{"status": "SERVING"}`; `list` named
`grpc.health.v1.Health` and both reflection services. check.sh repeats
those rows from a container on `kind-eg` (no Go cache) and matches
`"status": "SERVING"` exactly.

**6. The browser is the same door without `/etc/hosts`.**
apply.sh launches Chrome headless with `--host-resolver-rules` mapping
the API name to `.100` (gotcha #121: Chrome 153 writes the PNG and
never exits). The wait is for the file; Chrome is killed
(`chrome_rc=143`). The third apply recorded `chrome_rc=124` and
`PNG image data, 1000 x 500`. Chrome asks for `text/html`; `jsonview`
renders the three orders as a page — that is why `:80` has no
redirect. `hosts-entries.sh` printed the two names at 2026-09-19T14:18Z
and never writes `/etc/hosts`. One `Certificate` `eg-poc1-tls` covers
both names (the card has the spec and the issued leaf). Gateways live
in `shop` with the Secret, so no ReferenceGrant. Behind the doors:
`shopapi:local` with `shop-db`, and `routedemo:local -mode grpc` with
`appProtocol: kubernetes.io/h2c`. No docker build — `kind load` of
the existing images when a node lacks them. The final table: both
doors `Programmed=True`, class `kube-vip.io/kube-vip-class`, announced
by `eg-poc1-worker`, HTTP `200/eg-poc1` and GRPC `SERVING`. `check.sh`
at 2026-09-19T14:20:02Z: 15 PASS, 0 FAIL.

**The reference card — names, addresses, certificates, doors.** Read
from the live objects after apply (`hosts-entries.sh`,
`kubectl get gateway,certificate -n shop`, `openssl x509` on
`secret/eg-poc1-tls`). Addresses are the plan in enhancement 007
§3.1; the answering node is whoever kube-vip elected — this run, both
doors on `eg-poc1-worker`.

*The names and their addresses.* The lab has no DNS server for
`.poc.local`. `hosts-entries.sh` prints the records from live
state. curl and grpcurl use `--resolve` / `-authority`; Chrome's
screenshot uses `--host-resolver-rules`.

| Name | Address | What it is | Who answers for it |
|---|---|---|---|
| `api.eg-poc1.poc.local` | `172.19.255.100` | the HTTP door — `/healthz`, `/orders`, the browser | `eg-poc1-worker` (`fa:1f:d6:0f:1e:ae`) |
| `grpc.eg-poc1.poc.local` | `172.19.255.101` | the gRPC door — Health, both reflection services | `eg-poc1-worker` (`fa:1f:d6:0f:1e:ae`) |

*The certificate.* **One `Certificate` for the cluster — not one per
door.** Both Gateways reference `eg-poc1-tls` in `shop` (no
ReferenceGrant). Two dnsNames because an HTTPRoute and a GRPCRoute
may not share a hostname, and this lab puts them on two Gateways.

```yaml
kind: Certificate                     # cert-manager.io/v1, namespace shop
spec:
  secretName: eg-poc1-tls
  commonName: api.eg-poc1.poc.local   # the CN is the HTTP name
  duration: 2160h                     # 90 days
  renewBefore: 720h                   # 30 days
  dnsNames:
    - api.eg-poc1.poc.local
    - grpc.eg-poc1.poc.local
  issuerRef: {kind: ClusterIssuer, name: eg-ca-issuer}   # → CA secret eg-root-ca, .tmp/eg-poc1-root-ca.crt
```

The issued leaf (`print_leaf`, third apply):
`subject=CN=api.eg-poc1.poc.local`,
`DNS:api.eg-poc1.poc.local, DNS:grpc.eg-poc1.poc.local`,
`notAfter=Dec 18 13:14:14 2026 GMT`,
`sha256=15:4B:20:78:0E:BD:71:EB:C4:18:AF:B0:6C:68:53:C3:A6:54:75:B5:55:7C:7F:DF:8B:7C:38:A8:84:6A:4E:2D`.
`print_leaf` does not print a serial.

*The doors.*

```text
                  MacBook
           curl / grpcurl / browser
                    │
     ┌──────────────┴──────────────┐
     │                             │
     ▼                             ▼
 http-gw                    grpc-gw
 172.19.255.100             172.19.255.101
 api.eg-poc1.poc.local      grpc.eg-poc1.poc.local
  http :80  → 200           h2c :80  → SERVING
  https:443 → 200           https-grpc:443 → SERVING
     │                             │
     ▼                             ▼
 shopapi                    grpc (routedemo -mode grpc)
 X-Served-By: eg-poc1       appProtocol: kubernetes.io/h2c
     │
     ▼
 shop-db (postgres:16-alpine, this demo)
```

**What the review caught.** OB3 (Claude Opus 5), Codex and Grok,
2026-09-19, `docs/REVIEW_DEMO54.md`: the record had lost `.100`'s
`successful add IP` to kubectl's 10-lines-per-pod default; `check.sh`
accepted `True` as a ready count, a `/32` on the wrong node and a curl
that failed after good headers; `cleanup.sh` deleted the cloud-provider
before the door Services it must release; `browser_shot` waited 60 s for
a file written in 1.4 s; #120 cited two unrecorded figures. The
`deprecated` explanation two reviewers called wrong is what kube-vip's
and the kernel's source say — it stayed, with the reconciliation.

**What you can do with it right now.**

- `curl --resolve api.eg-poc1.poc.local:80:172.19.255.100 http://api.eg-poc1.poc.local/healthz` — 200 and `X-Served-By: eg-poc1`.
- `go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -plaintext -authority grpc.eg-poc1.poc.local 172.19.255.101:80 grpc.health.v1.Health/Check` — `{"status": "SERVING"}`.
- `demos/54-eg-poc1-kube-vip/hosts-entries.sh` then open `http://api.eg-poc1.poc.local/orders` in the browser.
- `demos/54-eg-poc1-kube-vip/check.sh` — 15 PASS.

**Where the next demo starts.** Demo 52 installs MetalLB on the
two-cluster lab. The fail cases stay in demo 51.
