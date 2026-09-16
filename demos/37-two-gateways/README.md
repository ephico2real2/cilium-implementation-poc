# Demo 37 — two ways to deploy a Gateway: the platform's shared door and a team's own

## Summary context

A Cilium Gateway is a Service and a `CiliumEnvoyConfig` — no Deployment, no pods. The data plane is the per-node
`cilium-envoy` DaemonSet, shared by every Gateway and every L7 policy on the node. A team's own Gateway is
another set of listeners in the same Envoy process: its own address, listeners, certificates, ownership — not
its own CPU. kgateway, Envoy Gateway and Istio deploy a proxy per Gateway; Cilium does not.

Every HTTP application in this lab sits behind one Gateway, `routes/routes-gw`, and both ways a route may attach
to it are already measured: the Gateway's namespace owning the route with a `ReferenceGrant` for the backend, or
the app's namespace owning its route with the Gateway admitting namespaces by label (PR #17, demo 09 Part 2). That
is the platform model — one address, one wildcard certificate, one Envoy configuration, many teams. This demo is
the other model the Gateway API was designed for: **a team's own Gateway in its own namespace**, for the cases a
shared proxy serves badly. One image, two front doors, measured side by side on poc1.

- **Mode A — the platform's shared Gateway.** Namespace `team-a` (label `gateway-access: routes-gw`) owns an
  `HTTPRoute` for `shop-a.poc.local` on `routes-gw`'s `https-wildcard` listener (and the 301 on `http`). Nothing
  new on the Gateway: this is PR #17's model, exercised by a team.
- **Mode B — the team's own Gateway.** Namespace `team-b` owns `Gateway/team-b-gw` (`gatewayClassName: cilium`,
  `allowedRoutes: {namespaces: {from: Same}}`, address pinned to `172.18.255.243`), one HTTPS listener for
  `*.team-b.poc.local` with a cert-manager wildcard from `ca-issuer`, one HTTP listener carrying the 301. A `Role`
  in `team-b` granting `gateways`/`httproutes` — the platform's explicit grant, not a default (`edit` does not
  cover Gateway API objects).
- **Two doors on one app.** `team-b-gw`'s route also points at `team-a`'s Service through a `ReferenceGrant` in
  `team-a`. The JSON identifies the request; the address, the leaf, and `X-Door` identify the door.

Convention: platform pages at `<name>.poc.local` on `routes-gw`; team doors at `*.<team>.poc.local`. TLS wildcards
are single-label, so the shared `*.poc.local` leaf cannot cover a team name (measured). Gateway API wildcards are
multi-label, so attachment elsewhere is not prevented: the admission policy in `50-` is the control.

## Files

| File | What |
|---|---|
| [`00-namespaces.yaml`](00-namespaces.yaml) | `team-a` (labelled for `routes-gw`) and `team-b` (not) |
| [`10-app.yaml`](10-app.yaml) | Deployment + Service `shop` in each namespace, `routedemo:local` |
| [`20-shared-route.yaml`](20-shared-route.yaml) | team-a's serving and 301 routes on `routes-gw` |
| [`30-team-gateway.yaml`](30-team-gateway.yaml) | `team-b-gw`, pinned `.243`, `*.team-b.poc.local`, two routes |
| [`35-team-rbac.yaml`](35-team-rbac.yaml) | SA `team-b-dev`, Role `gateway-owner`, bound with `edit` |
| [`40-one-app-two-doors.yaml`](40-one-app-two-doors.yaml) | `shop-a` via `team-b-gw`, ReferenceGrant in `team-a` |
| [`50-hostname-policy.yaml`](50-hostname-policy.yaml) | ValidatingAdmissionPolicy: claim only your own zone |
| [`hosts-entries.sh`](hosts-entries.sh) | prints the `/etc/hosts` block; never writes |
| [`check.sh`](check.sh) | evidence printer for the two doors, the hijack, the policy, RBAC |

## Run

```bash
kubectl --context kind-poc1 apply -f demos/37-two-gateways/00-namespaces.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/10-app.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/20-shared-route.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/30-team-gateway.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/35-team-rbac.yaml
kubectl --context kind-poc1 apply -f demos/37-two-gateways/40-one-app-two-doors.yaml
demos/37-two-gateways/hosts-entries.sh | sudo tee -a /etc/hosts
demos/37-two-gateways/check.sh
```

`50-hostname-policy.yaml` is applied by `check.sh`'s negative section and left applied.

## Part 1 — the two doors

recorded after the run.

## Part 2 — the certificates

recorded after the run.

## Part 3 — the answers

recorded after the run.

## Part 4 — the negatives

recorded after the run.

## Part 5 — RBAC

recorded after the run.
