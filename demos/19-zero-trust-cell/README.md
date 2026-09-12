# Demo 19 — a zero-trust cell for the bank, across both clusters: policy derived from intent, owned by the platform

## Summary context

The Cilium blog post [Zero-Trust Developer Platforms with Cilium Network Policies](https://cilium.io/blog/2026/08/28/zero-trust-developer-platforms-with-cilium-network-policies/)
(2026-08-28) argues that installing Cilium gives you the *mechanism* for zero trust and that a
developer platform should make it the *default*: a developer declares an endpoint's **visibility**
(`project` / `namespace` / `internal` / `external`), the platform renders a `CiliumNetworkPolicy`
from it at deployment time, default-deny is "a byproduct of the component having a policy at all",
and the platform owns the cell boundary "by construction rather than by convention". Its worked
example is OpenChoreo; this demo does the same thing by hand for the bank, with one difference the
post does not cover: **the cell spans two clusters over ClusterMesh**, and that changes the selectors.

What is here, all recorded in [`output/transcript.txt`](output/transcript.txt):

| File | Role in the blog's model |
|---|---|
| [`intent.yaml`](intent.yaml) | the developer-facing surface: one visibility list per component, nothing else |
| [`render.py`](render.py) | the platform: intent → seven `CiliumNetworkPolicy` objects, ingress only, `http: [{}]` on HTTP ports, **cluster-aware** |
| [`rendered/cell-policies.yaml`](rendered/cell-policies.yaml) | the output — applied unchanged to **both** clusters |
| [`10-platform-baseline.yaml`](10-platform-baseline.yaml) | the platform-owned cell boundary: a `CiliumClusterwideNetworkPolicy` — DNS, the cell across the mesh, an FQDN allowlist, a deny for the API server |
| [`20-rbac.yaml`](20-rbac.yaml) | the developer role: deploys and declares, reads policy, writes none |
| [`egress-test.sh`](egress-test.sh), [`drops.sh`](drops.sh) | the boundary probed from a debug pod; what Hubble denied and which policy did it |

## Part 0 — one prerequisite: external names must resolve (gotcha #63)

The blog's egress example allows `api.stripe.com` by name. On this rig no pod could resolve any
external name: CoreDNS forwards to the node's `/etc/resolv.conf`, which on Docker Desktop is
`192.168.65.254`, and that resolver times out for pod-sourced packets (46 `i/o timeout` errors in
30 min; the same query straight to `1.1.1.1` from a pod answered at once). CoreDNS in both clusters
now forwards to `1.1.1.1 8.8.8.8` — a one-line Corefile change, reversible from `.tmp/Corefile-*-before`:

```
  poc1 pod: https://example.com  http 200
  poc1 pod: https://api.stripe.com  http 404        ← reached; 404 is Stripe's answer to GET /
  poc2 pod: api.stripe.com answers via coredns: 3
```

## Part 1 — the cell, on both clusters; the bank must not notice

**First, the two demo 16 visibility policies had to go.** They were allow-all (`toEntities: [all]`,
`fromEntities: [all]`) and any allow anywhere defeats a deny by omission. The cell policies carry the
same `http: [{}]` and `dns` rules, so nothing observable is lost.

**Then the platform baseline, then the rendered policies — the same two files on each cluster**
("it is your responsibility to apply policy in all clusters", ClusterMesh docs):

```bash
demos/19-zero-trust-cell/render.py < demos/19-zero-trust-cell/intent.yaml > demos/19-zero-trust-cell/rendered/cell-policies.yaml
for c in poc1 poc2; do
  kubectl --context kind-$c apply -f demos/19-zero-trust-cell/10-platform-baseline.yaml
  kubectl --context kind-$c apply -f demos/19-zero-trust-cell/rendered/cell-policies.yaml
done
```

```
  bank-cell-baseline   True                            (both clusters)
  CNP                     VISIBILITY         VALID
  cell-accounts           project            True
  cell-api                external,project   True
  cell-payments           project            True
  cell-postgres           project            True
  cell-postgres-standby   project            True
  cell-redis              project            True
  cell-web                external           True

  app=web        policy-enabled=both   proxy=['53/egress', '8080/ingress']     ← ingress AND egress enforced now
  app=payments   policy-enabled=both   proxy=['53/egress', '8080/ingress']
  app=api        policy-enabled=both   proxy=['53/egress', '8080/ingress']
```

**Did the bank notice?** Two runs of the 40-call exercise:

```
  first run, ~10 s after apply:  calls: 40  ok: 38  FAILED (infrastructure): 2     ← two 503s from the Gateway while the
                                                                                     endpoints regenerated with the L7 redirect
  second run:                    calls: 40  ok: 40  FAILED: 0   payments served by : poc2=27 poc1=13   LEDGER CONSISTENT
  scripts/check-routes.sh:       FAILED CHECKS: 0
  replication: standby=10.10.4.188/32 streaming lag=00:00:00.001834                ← postgres-standby (poc1) → postgres (poc2), in-cell
  https://bank.poc.local -> 200
```

Active-active across the mesh, replication across the mesh, the Gateway, the UI — all inside a
default-deny cell. What Hubble denied in those minutes: nothing from the bank's own pods.

## Part 2 — the egress boundary, from a developer's debug pod

A `kubectl run` alpine pod in `bank` declares nothing, so it gets no rendered policy: **open
ingress, the platform's egress**. That is the blog's point about ownership — the developer did not
opt in. [`egress-test.sh`](egress-test.sh), on the Service ports:

```
  in-cell: api.bank:80/healthz (Service port)                ALLOWED
  in-cell, other cluster: accounts.bank:80/healthz           ALLOWED      ← poc2, via the cluster-aware rule
  in-cell: redis.bank:6379 (tcp)                             ALLOWED
  DNS: nslookup example.com                                  ALLOWED      ← DNS is allowed; connecting is not
  FQDN allowlist: api.stripe.com:443                         ALLOWED
  FQDN allowlisted name, port NOT listed: api.stripe.com:80  DENIED
  world by name, not listed: example.com:443                 DENIED
  world by IP: 1.1.1.1:443                                   DENIED
  kube-apiserver (egressDeny): kubernetes.default:443        DENIED
  another namespace: echo.routes:80                          DENIED
  a Service IP on a port that is not a Service port: api.bank:8080   DENIED   (gotcha #64)
```

And the same from Hubble, with the policy named where a *deny rule* did it:

```
    24  egress-test@poc1  -> reserved:world           :80    POLICY_DENIED   denied_by=[]                    ← denied by omission: no rule to name
    20  egress-test@poc1  -> reserved:world           :443   POLICY_DENIED   denied_by=[]
     5  egress-test@poc1  -> reserved:kube-apiserver  :6443  POLICY_DENY     egress denied_by=['bank-cell-baseline']   ← the explicit deny
```

**A retraction, kept in the transcript.** The first version of this test used `api.bank:8080` and
reported in-cell traffic as denied with the destination classified `world`. The datapath debug log
showed why: the Service is `10.11.36.138:80 → 10.10.3.34:8080`; `:8080` on the ClusterIP is not a
Service frontend, so no translation happens and the address is an unknown IP — `world`. Not a
Cilium anomaly, a wrong port; gotcha #64 so nobody else spends twenty minutes on it.

## Part 3 — the mesh trap: what a single-cluster template does to a two-cluster cell (gotcha #62)

The blog's rendered policy admits the cell with `fromEndpoints: [{}]`. Since Cilium 1.19,
`policy-default-local-cluster=true` (set on both clusters here) makes such a selector match **the
local cluster only**. `render.py --local-cluster-only` produces exactly that; the diff against the
committed rendering is one expression per rule:

```
<       matchExpressions: [{key: io.cilium.k8s.policy.cluster, operator: In, values: [poc1, poc2]}]
```

Applied to poc2 (where `accounts` and one `payments` live):

```
  calls: 12  ok: 4  FAILED (infrastructure): 8         ← every call that crossed the mesh
== poc2: 400 dropped flows ==
   164  api@poc1               -> payments@poc2   :8080  POLICY_DENIED
   112  payments@poc1          -> accounts@poc2   :8080  POLICY_DENIED
   104  api@poc1               -> accounts@poc2   :8080  POLICY_DENIED
    20  postgres-standby@poc1  -> postgres@poc2   :5432  POLICY_DENIED   ← replication too
```

Restored the cluster-aware rendering: `20/20, payments served by poc2=9 poc1=11`. The renderer
writes the cluster expression into every cell selector from `intent.cell.clusters`, so the developer
never sees it — which is the blog's argument for a platform that renders policy instead of humans
copying templates.

## Part 4 — governance: who can write policy

The blog: "the platform team keeps control over any exceptions". Here that is RBAC, not a
convention — [`20-rbac.yaml`](20-rbac.yaml):

```
  can-i create deployments -n bank                           yes
  can-i create ciliumnetworkpolicies.cilium.io -n bank       no
  can-i update ciliumnetworkpolicies.cilium.io -n bank       no
  can-i get ciliumnetworkpolicies.cilium.io -n bank          yes     ← they can read what was rendered for them
  can-i create ciliumclusterwidenetworkpolicies.cilium.io    no
  can-i delete ciliumclusterwidenetworkpolicies.cilium.io    no
  the developer tries to open the world anyway:
    Error from server (Forbidden): … cannot create resource "ciliumnetworkpolicies" … in the namespace "bank"
```

And the one rule RBAC cannot express — "never, even if someone with rights allows it" — is the
`egressDeny` in the clusterwide baseline: deny rules take precedence over allow rules "regardless of
whether they are a Cilium Network Policy, a Clusterwide Cilium Network Policy or even a Kubernetes
Network Policy" (Cilium docs, deny policies). They cannot express L7 or FQDN, which is why the
allowlist above is an *allow* and the API-server rule is a *deny*.

## Part 5 — intent changes, policy follows

Drop `project` from `api` (only the Gateway may call it), re-render, apply to both clusters. The
Gateway still gets 200 from `bankapi.poc.local`; `web`, inside the cell, is now denied — from
Hubble, since web's page still renders while its server-side call fails:

```
<   api: {… visibility: [external, project]}
>   api: {… visibility: [external]}
  poc1: ciliumnetworkpolicy.cilium.io/cell-api configured        poc2: … configured
  Gateway -> api (external): 200
== poc1: 12 dropped flows ==
    12  web@poc1  -> api@poc1  :8080  POLICY_DENIED
```

Re-render from the committed `intent.yaml`: `cell-api configured`, `Gateway -> web -> api: 200`.
The policy was never edited; the intent was.

## Part 6 — the same story on the demo 16 dashboards

`hubble_drop_total` with the Part 9 contexts names the peers:

```
sum by (source, destination, reason) (increase(hubble_drop_total{source_namespace="bank"}[20m]) > 0)
     155.9  source=egress-test  destination=reserved:world           reason=POLICY_DENIED
     20.26  source=egress-test  destination=reserved:kube-apiserver  reason=POLICY_DENY
     15.42  source=web          destination=api                      reason=POLICY_DENIED
```

That is the "Hubble / Network Overview (Namespace)" drops panel, and it is how a platform team
tightens a policy safely: see the traffic, then deny what is not there.

## What to take away

- **The blog's model works as described, by hand.** Seven rendered policies + one clusterwide
  baseline gave the bank a default-deny cell with zero failed requests after the first seconds.
- **A cell that spans a mesh needs cluster-aware selectors** — `io.cilium.k8s.policy.cluster In [...]`
  on every `fromEndpoints`/`toEndpoints` — or the peer cluster is silently outside the cell
  (gotcha #62). Put it in the renderer, not in the developer's hands.
- **Ownership is RBAC + a clusterwide object + deny rules** for the lines that must not move; the
  allowlists (FQDN, in-cell) are allow rules because deny cannot express them.
- **Test on Service ports** (gotcha #64), and read the drops with `drops.sh` before concluding
  anything — the datapath verdict log is the ground truth.
- **The cell stays on.** Demos 15, 16 and 18 keep running under it; the visibility policies from
  demo 16 Part 7 are superseded by the rendered ones (same `http: [{}]`, same `dns` rule).

Remove it all:

```bash
for c in poc1 poc2; do kubectl --context kind-$c delete -f demos/19-zero-trust-cell/rendered/cell-policies.yaml --ignore-not-found; kubectl --context kind-$c delete -f demos/19-zero-trust-cell/10-platform-baseline.yaml --ignore-not-found; done
kubectl --context kind-poc1 delete -f demos/19-zero-trust-cell/20-rbac.yaml --ignore-not-found
```
