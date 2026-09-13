# crds — the CustomResourceDefinitions this lab installs, vendored

Fetched once, committed, applied from here: a cluster bring-up must not depend on GitHub's raw endpoint being up,
and a reviewer must be able to read what was applied. Every file carries its upstream `bundle-version` annotation.

| Directory | What | Fetched from | Applied by |
|---|---|---|---|
| `gateway-api/v1.6.1/` | the ten Gateway API v1.6.1 CRDs — GatewayClass, Gateway, HTTPRoute, ReferenceGrant, GRPCRoute, BackendTLSPolicy, TLSRoute, ListenerSet, TCPRoute, UDPRoute (all from the `standard` channel at v1.6.1) | `https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/` | `scripts/gateway-api-crds.sh` |

Why all ten: `cilium sysdump` collects every Gateway API kind and warned `the server could not find the requested
resource` for TLSRoute, GRPCRoute, TCPRoute and UDPRoute when only the seven of demo 05 were installed; Cilium
1.20.1's Gateway API implementation serves TLSRoute and GRPCRoute, and the sysdump is the lab's evidence file.

Refresh (a new Gateway API version): change the version in the loop, fetch into a new directory, point the script
at it, and say in the demo that uses it what changed.

```bash
V=v1.6.1; mkdir -p crds/gateway-api/$V && cd crds/gateway-api/$V
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes listenersets tcproutes udproutes; do
  curl -sSfL -O "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$V/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml"
done
```
