# PARKED — demo 11: prove Cilium BGP with an FRR router on the docker network

**Status: parked, not built (2026-09-11).** Researched and planned so it can be resumed in the
background. Nothing in this file has been executed against the clusters; every command below is
marked *planned* until the demo's transcript exists.

## Why it is parked, in one line

Today every LoadBalancer address is reachable by **L2 announcement** and nothing on the docker
network speaks BGP — measured: 0 listeners on TCP 179 in the Docker VM, `172.18.0.1:179` refuses.
A BGP demo therefore needs a router that does not exist yet. That router is the whole demo.

## What the demo would prove (the network-team sentence)

> The nodes *advertise* the service VIP block to the top-of-rack router; nothing is configured on
> the router by hand, a VIP is reachable from a network that is **not** the node LAN, every node
> announces it (ECMP), and killing a node withdraws its path within the BGP hold time.

That is the production substitution named in `NETWORKING_DESIGN.md` §5.3 option B and §7 — L2 for
the lab, BGP for the data centre. Building it closes the one layer the design doc describes but
does not measure.

## Research (done)

| Source | What it settles |
|---|---|
| [Cilium BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/) (1.20.1) | `bgpControlPlane.enabled=true`; CRs `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement` |
| [Cilium's own kind + FRR lab](https://github.com/cilium/cilium/tree/v1.20.1/contrib/containerlab/service) (`contrib/containerlab/service`) | The canonical reference: `frrouting/frr:v8.4.0`, eBGP, `no bgp ebgp-requires-policy`, `bgp bestpath as-path multipath-relax`, a `CILIUM` peer-group with `remote-as external`; Cilium side `advertisementType: Service` + `service.addresses: [LoadBalancerIP]` selected by a label; nodes labelled `bgp=65001` and selected by `nodeSelector`. Files copied to the session scratchpad (`clab/`) and quoted below. |
| [BGP CP dev docs](https://docs.cilium.io/en/stable/contributing/development/bgp_cplane/) | Same lab via `make kind-bgp-service`; uses **containerlab** + veth links + IPv6 peering + native routing — heavier than we need |
| [Calico + FRR on macOS write-up](https://medium.com/@dwiveditanuj41/exposing-kubernetes-service-using-calico-cni-and-frrouting-bgp-on-macos-8a3369f65015) | Enable `bgpd=yes` in `/etc/frr/daemons`; the docker **userland-proxy** rewrites source IPs and breaks peering **only for published ports** — we publish none, so it does not apply |
| CRD source at `v1.20.1` (`pkg/k8s/apis/cilium.io/client/crds/v2/ciliumbgpadvertisements.yaml`) | served versions `v2`, `v2alpha1`; `advertisementType` enum `PodCIDR, CiliumPodIPPool, Service, Interface`; `service.addresses` enum `LoadBalancerIP, ClusterIP, ExternalIP`; `selector` present |

The snippet that prompted this (peer `172.18.0.1`, ASN 65002) is a template that assumes a router
at the docker gateway. There is none; the plan below puts one there.

## Design — the smallest thing that is a real BGP demo

Cilium's lab wires veth links with containerlab. We do not need that: every kind node already
shares one L2 segment, the `kind` docker network, so **an FRR container on that same network is
directly adjacent to every node** — exactly a ToR switch/router with all servers on its access
VLAN.

```
 Mac ──(route 10.99.0.0/24 via 192.168.64.2)──► Docker VM ──(route 10.99.0.0/24 via 172.18.0.250)──► FRR "tor0"
                                                                                                        172.18.0.250  AS 65000
                                                                                                        │ eBGP, dynamic neighbours
                                                                                                        │ learns 10.99.0.1/32 from EVERY node (ECMP)
                                                          ┌──────────────┬──────────────┬───────────────┤
                                                       .0.3 cp3       .0.4 worker2   .0.5 worker     .0.6/.0.7 cp, cp2     AS 65001
                                                          └── Cilium BGP: advertise LoadBalancerIP of Services labelled bgp=tor ──┘
                                                                                  bgp-pool  10.99.0.0/24   (a THIRD pool, OFF the LAN)
```

Design decisions, each with its reason:

1. **The BGP pool is outside `172.18.0.0/16`: `10.99.0.0/24`.** If the VIP were on the LAN, the
   existing Mac route and L2 ARP would reach it anyway and BGP would prove nothing. Off-LAN, the
   *only* way in is the route FRR learned. It does not overlap pods (`10.10`, `10.20`), services
   (`10.11`, `10.21`) or the node LAN.
2. **A third `CiliumLoadBalancerIPPool` (`bgp-pool`) with its own selector** (`bgp: tor` label),
   so the two existing pools and their L2 behaviour are untouched. The advertisement's `selector`
   matches the same label — only opted-in Services go to BGP.
3. **FRR gets a fixed address, `172.18.0.250`, via `docker run --ip`.** Nodes are `.0.2–.0.10` and
   Docker allocates upward, so `.250` is safe for the life of this lab; it is below the LB ranges
   at `.255.x`. Note the caveat: Docker does not *reserve* it (the `kind` network has no
   `--ip-range`), it is simply never reached.
4. **Dynamic neighbours on FRR (`bgp listen range 172.18.0.0/16 peer-group CILIUM`)**, not one
   `neighbor` line per node — node IPs reshuffle on a Docker restart (README finding #3) and this
   repo never references a node by IP. Cilium's lab lists neighbours statically; that is the one
   place we deliberately differ.
5. **eBGP, AS 65000 (router) / 65001 (cluster)** as in Cilium's lab; `no bgp ebgp-requires-policy`
   because FRR ≥ 7.x drops eBGP routes without an explicit policy — Cilium's lab sets it for the
   same reason. `bgp bestpath as-path multipath-relax` so the /32 from every node becomes an ECMP
   route, which is the "every node announces" proof.
6. **The router must forward:** `--sysctl net.ipv4.ip_forward=1` on the FRR container, and FRR's
   zebra installs the learned /32 into the container's kernel table (default behaviour) — that is
   what actually moves the packet from the VM to a node.
7. **Two static routes to reach the block from outside**, mirroring the design doc's layering:
   the Mac points `10.99.0.0/24` at the VM (`sudo route …`, user runs it), and the VM points it at
   FRR (added with `nsenter`, since the VM is the Linux host in this topology). On a Linux server
   it is one `ip route add 10.99.0.0/24 via 172.18.0.250`.
8. **Leave `routingMode: tunnel` as is.** Service VIP advertisement does not depend on native
   routing; only PodCIDR advertisement would (and we are not advertising it). **Verify at build
   time** — this is the one assumption not yet measured; Cilium's lab runs native routing.
9. **poc1 only.** poc2 stays out; ClusterMesh is unaffected.
10. **L2 and BGP coexist** on different pools. Keep it that way — the comparison (same cluster,
    L2 pool vs BGP pool) is the teaching moment.

## Planned build (junior-guide form, every command to be recorded with `scripts/record.sh`)

### 1. The router

```bash
# planned — image: Docker Hub frrouting/frr STOPS at v8.4.1 (2022-12-01, measured via the Hub API);
# FRR publishes current releases on quay.io (10.7.1 on 2026-08-26). Pin quay, and verify at build
# time that the FRR 10 image still ships /usr/lib/frr/frrinit.sh and /etc/frr/daemons as 8.4 did.
docker run -d --name tor0 --network kind --ip 172.18.0.250 \
  --privileged --sysctl net.ipv4.ip_forward=1 \
  quay.io/frrouting/frr:10.7.1
docker exec tor0 sh -c 'sed -i s/bgpd=no/bgpd=yes/ /etc/frr/daemons && touch /etc/frr/vtysh.conf && /usr/lib/frr/frrinit.sh restart'
docker exec tor0 vtysh -c 'conf t' \
  -c 'router bgp 65000' \
  -c ' bgp router-id 172.18.0.250' \
  -c ' no bgp ebgp-requires-policy' \
  -c ' bgp bestpath as-path multipath-relax' \
  -c ' neighbor CILIUM peer-group' \
  -c ' neighbor CILIUM remote-as external' \
  -c ' bgp listen range 172.18.0.0/16 peer-group CILIUM' \
  -c ' address-family ipv4 unicast' \
  -c '  neighbor CILIUM activate' \
  -c ' exit-address-family' \
  -c 'end' -c 'write'
docker exec tor0 vtysh -c 'show bgp summary'          # expect: 0 neighbours yet, listen range shown
```

### 2. Cilium side (values + CRs, committed as `demos/11-bgp/`)

```yaml
# cilium/values-poc1.yaml — planned addition
bgpControlPlane:
  enabled: true
```

```bash
helm upgrade cilium cilium/cilium -n kube-system --version 1.20.1 -f cilium/values-poc1.yaml --kube-context kind-poc1
kubectl --context kind-poc1 label node --all bgp=65001          # the nodeSelector below
```

```yaml
# demos/11-bgp/01-bgp.yaml — planned; shapes copied from Cilium's lab, addresses ours
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: tor}
spec:
  nodeSelector: {matchLabels: {bgp: "65001"}}
  bgpInstances:
    - name: "65001"
      localASN: 65001
      peers:
        - name: tor0
          peerASN: 65000
          peerAddress: 172.18.0.250
          peerConfigRef: {name: tor-peer}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: tor-peer}
spec:
  authSecretRef: bgp-auth-secret          # kube-system Secret, key `password`; FRR: neighbor CILIUM password <same>
  gracefulRestart: {enabled: true, restartTimeSeconds: 15}
  # timers: run 1 with the defaults (hold 90 / keepalive 30); run 2 with {holdTimeSeconds: 9, keepAliveTimeSeconds: 3}
  families:
    - afi: ipv4
      safi: unicast
      advertisements: {matchLabels: {advertise: bgp}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata: {name: lb-vips, labels: {advertise: bgp}}
spec:
  advertisements:
    - advertisementType: Service
      service: {addresses: [LoadBalancerIP]}
      selector: {matchExpressions: [{key: bgp, operator: In, values: [tor]}]}
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: bgp-pool}
spec:
  blocks: [{cidr: "10.99.0.0/24"}]
  serviceSelector: {matchExpressions: [{key: bgp, operator: In, values: [tor]}]}
```

```yaml
# demos/11-bgp/02-service.yaml — planned: the routes demo's web app, exposed a second time via BGP
apiVersion: v1
kind: Service
metadata: {name: web-bgp, namespace: routes, labels: {bgp: tor}}
spec:
  type: LoadBalancer
  selector: {app: web}
  ports: [{port: 80, targetPort: 8080}]
  externalTrafficPolicy: Local     # then flip to Cluster: Local = only nodes WITH a backend advertise
```

### 3. Proof, in order

```bash
cilium bgp peers --context kind-poc1                                  # every node: session established
cilium bgp routes advertised ipv4 unicast --context kind-poc1        # 10.99.0.x/32 from each node
docker exec tor0 vtysh -c 'show bgp summary'                          # N dynamic neighbours, Up
docker exec tor0 vtysh -c 'show ip bgp 10.99.0.1/32'                  # multipath, one path per node
docker exec tor0 ip route show 10.99.0.1                              # kernel ECMP nexthops = node IPs
# reach it from OUTSIDE the LAN — the routes are the design doc's layering, one per hop:
docker run --rm --privileged --pid=host --net=host alpine nsenter -t 1 -n ip route add 10.99.0.0/24 via 172.18.0.250   # VM -> FRR
sudo route -n add -net 10.99.0.0/24 192.168.64.2                      # Mac -> VM  (user runs it)
traceroute -n 10.99.0.1                                               # hop1 VM, hop2 172.18.0.250 (FRR), then a node
curl -s -H 'Host: web.poc.local' http://10.99.0.1/                    # 200 via BGP, not via L2
# failure: withdraw a path
docker pause poc1-worker; sleep 95; docker exec tor0 vtysh -c 'show ip bgp 10.99.0.1/32'   # one path gone (hold 90s)
docker unpause poc1-worker
# ECMP vs Local: scale web to 1 replica with externalTrafficPolicy Local -> exactly one path
```

### 4. What to record

`demos/11-bgp/README.md` + `output/transcript.txt`; a Hubble view of the same request (source
identity `world`, ingress via a node, not via the ingress proxy); a `FINDINGS.md` entry with the
measured withdraw time; a GOTCHAS entry for anything that bit; and the `NETWORKING_DESIGN.md` §5.3
option B row upgraded from "planned" to "measured" with the diagram above added as §2b.

## Configuration reference — merged from the Cilium 1.20.1 docs and the snippets collected (2026-09-11)

Every item below is from
[bgp-control-plane-configuration](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)
(stable = 1.20.1) or from the snippets pasted in; the right-hand column says whether it applies to
*this* design and why. Nothing here is guessed — the doc statements were fetched and quoted.

| Item | What the docs / snippet say | Applies here? |
|---|---|---|
| **Enable** | `helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --reuse-values --set bgpControlPlane.enabled=true` then `kubectl -n kube-system rollout restart ds/cilium` | **Yes, adapted.** This repo keeps every value in `cilium/values-poc1.yaml` and never uses `--reuse-values`/`--set` (gotcha #12: ad-hoc changes are reverted by the next upgrade). So: add `bgpControlPlane.enabled: true` to the values file, `helm upgrade … -f cilium/values-poc1.yaml`, then the `rollout restart` — the agents must restart to start the BGP goroutines. Record `cilium status --wait` after. |
| **`localPort: 179` + `CAP_NET_BIND_SERVICE`** | "Listening on the default BGP port (179) requires `CAP_NET_BIND_SERVICE`. If you wish to use the default port, you must grant the `CAP_NET_BIND_SERVICE` capability with `securityContext.capabilities.ciliumAgent` Helm value." And: "by default, the BGP Control Plane instantiates each router instance without a listening port" — Cilium is **active**, it dials the peer from an ephemeral port. | **Not needed.** We do not set `localPort`; Cilium dials FRR on 172.18.0.250:179 and FRR's `bgp listen range` accepts it. Setting `localPort: 179` would only matter if FRR were to *initiate* toward the nodes — it does not. Keep the agent's capabilities as shipped. |
| **`autoDiscovery: {mode: DefaultGateway}`** | Exists in 1.20.1: the peer address is taken from the node's default route instead of being written down. | **Not usable on kind, and worth a sentence in the demo.** Every node's default gateway is `172.18.0.1` — the docker bridge, which has no BGP speaker (measured: 0 listeners on :179). It would peer with the wrong box. In a real rack the ToR *is* the default gateway, so there it is the right choice and removes the peer IP from the config entirely. Our peer address is the one static value in the design (`172.18.0.250`). |
| **Timers** `holdTimeSeconds: 9`, `keepAliveTimeSeconds: 3` (snippet) vs defaults `90 / 30 / connectRetry 120` (docs) | Fast-failover timers. | **Yes — as the *second* run.** Measure node-withdraw time with the defaults first (expect ≤ 90 s), then with 9/3 (expect ≤ 9 s); both numbers go in FINDINGS. FRR's hold time negotiates down to the smaller side, so set it only on the Cilium side. |
| **`authSecretRef: bgp-auth-secret`** | TCP MD5 password from a Secret in `kube-system` (`kubectl -n kube-system create secret generic --type=string bgp-auth-secret --from-literal=password=…`); FRR side `neighbor CILIUM password …` — exactly Cilium's own lab. | **Yes, optional but cheap**, and it is the thing a network team will ask about ("is the session authenticated?"). Add to both sides; show `show bgp neighbors` reporting the session up with MD5. |
| **`ebgpMultihop: 4`** | Allows the peer to be several hops away. | **No.** FRR is on the same L2 segment as every node (TTL 1 is enough). Leave unset. |
| **`gracefulRestart: {enabled: true, restartTimeSeconds: 15}`** | Peer keeps our routes for 15 s if the agent restarts. | **Yes.** It is what makes the helm upgrade / agent restart later in the demo *not* drop the VIP. Show it: restart the DaemonSet, curl in a loop, no failed request. |
| **FRR `neighbor CILIUM local-as 65000 no-prepend replace-as`** (snippet, FRR in AS 65100 presenting as 65000) | Makes a router present a different ASN to a peer-group. | **No.** That trick is for matching an existing AS plan. Ours is plain eBGP: FRR **65000**, cluster **65001**, no rewriting — simpler to read on `show ip bgp`. |
| **FRR `bgp listen range <cidr> peer-group CILIUM`** (snippet, and Cilium's lab) | Dynamic neighbours: any node in the range may open a session. | **Yes — the core of the design** (decision 4): `bgp listen range 172.18.0.0/16 peer-group CILIUM`, so node IPs never appear in the router config. |
| **`nodeSelector: {matchLabels: {rack: rack0}}`**, two ToR peers (snippet) | One `CiliumBGPClusterConfig` per rack, each node peering with both ToRs. | **Later, if at all.** One rack, one ToR is the demo. The snippet is the production shape and is worth a paragraph in the README: with two FRR containers you would show dual-homing. |
| **IPv6 peering `fd00:10:0:0::1`** (snippet, Cilium lab) | Their lab peers over IPv6. | **No.** Our LAN is IPv4 (`172.18/16`); the `kind` network has an IPv6 subnet too but nothing in this PoC uses it. IPv4 keeps the diagram matching NETWORKING_DESIGN.md. |

## Open questions to answer at build time (not assumed)

1. Does `bgpControlPlane.enabled=true` coexist with `l2announcements.enabled=true` in 1.20.1 without
   the L2 leases flapping? (Expected yes — different pools — measure.)
2. Service VIP advertisement under `routingMode: tunnel` — confirm the /32 is advertised and the
   return path works over vxlan.
3. Does the FRR container need `--cap-add NET_ADMIN` only, rather than `--privileged`? Try the
   narrower one first.
4. Docker Desktop: does the VM route survive long enough to demo (it is lost on Docker restart —
   same as the Mac route, acceptable).

## Cost

One small container, no new cluster, one helm upgrade of poc1 (agents restart — do it when no
other demo is being recorded). Estimated 1–2 hours including the transcript.
