# What demo 41 did — the walk-through

**The goal.** Demo 40 built the doors: one shared public address, a door per cluster, certificates, and the switch
that moves the shared address between clusters. Demo 41 moves the furniture in. The shop platform from demo 35 — an
API gateway in front of catalog, orders, payments, merchant and reviews — now runs in *both* clusters as one
application, behind those doors, with its network policies generated from what the traffic actually did. It is phase 1
of enhancement 002; the database (phase 2), load (phase 4) and the failure drills (phase 5) come after.

**1. The same platform twice, and Cilium told it is one.** The manifest is byte-identical for both clusters — the
only per-cluster value is the cluster's name, handed to the backend through a small ConfigMap. Every service carries
two Cilium annotations: `service.cilium.io/global: "true"`, which makes a service with the same name and namespace in
both clusters *one* service across the mesh, and `service.cilium.io/affinity: local`, which says "use your own
cluster's copy while it is healthy". A new `backend` runs the `shopapi` program built in demo 40; the API gateway
proxies `/ready` and `/orders` to it so the client's contract holds end to end.

**2. What "prefer local" really does — decided from Cilium's source.** The first measurement looked odd:
`cilium-dbg service list` on poc1 showed catalog with only one backend, its own, and the other cluster's copy appeared
the moment the affinity annotation was removed. Cilium's code explains it. In `pkg/clustermesh/selectbackends.go`, the
function that picks a service's backends counts the healthy local ones and the healthy remote ones, then uses the
remote ones only when `localActiveBackends == 0`. The remote copy is not hidden from a listing — it is *not selected
into the datapath at all* while a local copy is active. The live tables say the same: poc1's backend table holds
**two** catalog backends, `10.10.0.46` from its own cluster and `10.20.0.135` from poc2 (source `clustermesh`), and the
kernel-side load-balancer map for catalog holds **one**. So the other cluster's copy is known and held in reserve, and
takes over the instant the last local one dies. `check.sh` now measures both numbers (`known=2 (clustermesh=1)
selected=1 local`); phase 5's scenario S2 will show the switch happen.

**3. One URL, and the answer says who served it.** Routes attach the API gateway to both doors in each cluster: the
shared address `api.shop.poc.local` and the per-cluster names `api.poc1.shop.poc.local` / `api.poc2.shop.poc.local`.
Each route carries a filter that makes the Gateway itself stamp `X-Served-By: <cluster>` on every response, and the
plain-HTTP listener answers a 301 to HTTPS. From the Mac: the shared address answers **200 `X-Served-By: poc1`** (poc1
announces it today), `.242` answers `poc1`, `.177` answers `poc2`. The header names the *door* the request entered, not
which cluster's pods did the work behind it — with local affinity the two coincide while local pods are healthy.

**4. Policies from the traffic, one set per cluster.** Following demo 35's method, each cluster's shop pods were put
in audit mode, real traffic was sent (the shopper, the clients through the doors), the flows were captured from Hubble,
and cf2cnp turned them into seven CiliumNetworkPolicies per cluster — then audit was switched off. The generated
selectors carry no cluster label, which on Cilium 1.19+ means "this cluster only"; that is right, because every flow in
phase 1 stays inside its cluster. The API gateway's policy admits the Gateway's own identity (`reserved:ingress`) and
the shopper; the stranger is not in it. Enforcement was then *measured*, not assumed: the stranger's call to catalog
times out (`wget: download timed out`), Hubble shows it as `DROPPED`, and the legitimate path api-gateway → catalog
shows as `FORWARDED`, in both clusters.

**5. Where the flows came from — a correction the review forced.** Hubble was read through the mesh relay, and the
relay returns flows from *both* clusters; poc1's capture file held 136 poc2 flows. The capture now filters by cluster
(`hubble observe --cluster <name>`, each flow's `node_name` is `<cluster>/<node>`). Filtering poc1's file down to its
own 78 flows lost the Gateway → api-gateway rule, because no traffic had gone through poc1's door in that window — so
the evidence was completed from poc1 alone (43 Gateway flows, then 30 api-gateway → backend flows; 151 in total), and
regenerating from that file reproduces every applied ingress rule identically. The regenerate also produced something
that was rejected: an egress policy with an **empty selector** in the `default` namespace, generated for the Gateway's
identity, which has no pod. Applied, an empty selector would match every pod in that namespace. That is a cf2cnp defect
and is filed on the fork as cf2cnp#7.

**6. What is deliberately unfinished.** `/ready` and `/orders` answer **503** — the backend's readiness is a real
`SELECT 1` against a database that does not exist until phase 2. `/healthz` is 200 everywhere. The doors, the header
and the policies are the phase-1 deliverable; the shop's data path is the next one.

**What the review caught** (Codex and Grok, `docs/REVIEW_DEMO41.md`; OB1's pass is owed — the Fable usage limit ended
it, and the affinity question it would have judged was decided from the source instead):

- The catalog check read past its own service in the listing and, replayed on its own transcript, counted
  `local=12 remote=12` for a service with one backend.
- The policy check accepted six of the seven policies and never read whether audit mode was actually off.
- Re-running the apply script deleted the enforced policies; it now removes demo 35's older set only the first time.
- No check measured the HTTP → HTTPS redirect; three rows now do, with the hostname (a bare IP cannot match a route).
- The probe accepted a stale `/etc/hosts` entry; it now compares the resolved address with the live shared address.
- The regression row reported an API error as "Gateway absent"; only a real NotFound is a skip now.
- The apply script's final table printed `X-Served-By=-` for a header it had just received (HTTP/2 lower-cases headers).

After the fixes: 33 of 33 checks pass on both clusters; the lab's regression check is 15 of 15 with the new row "the
shop's public URL answers from a cluster". The platform twice costs about **1.9 GiB** more memory on the Docker VM
(18.9 GiB now); CPU stays around one core.

**What you can do with it right now.**

- `curl -sk --resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/healthz -D -` — 200 and the
  serving cluster's name.
- `kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg statedb backends | grep
  shop-core/catalog` — two backends, one from the other cluster; then `cilium-dbg bpf lb list` — one selected.
- `demos/41-shop-mesh-phase1/probe.sh` — both clients against the URL (needs the `/etc/hosts` block from
  `demos/40-shop-mesh-phase0/hosts-entries.sh`).
- `demos/41-shop-mesh-phase1/check.sh` — the 33 checks with the rule each applies.

**Where the next demo starts.** Demo 42 gives the shop its database: PostgreSQL in poc1 only, published on a Gateway
with a TCP route and a pinned address under the name `db-service.poc.local`, reached by the backends in *both*
clusters — and by a DBA's laptop — exactly as an external database would be, with the backend's policy written as a
DNS name rather than a pod.
