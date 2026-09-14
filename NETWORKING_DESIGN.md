# NETWORKING DESIGN — read this before SETUP.md

This document is the network architecture of the PoC. It exists so that the addressing plan is a
**design decision made first**, not something discovered while a demo fails — and so that when you
sit down with the network team you can show *exactly* which addresses exist, where each one lives,
who answers for it, and how a laptop or a Linux server reaches it. Every output below was captured
from the live build on 2026-09-11 (Docker Desktop 4.27.2, docker 25.0.3, kind v0.33.0, VM kernel
6.6.12-linuxkit, Cilium 1.20.1). `scripts/network-plan.sh` reprints the whole plan from live state
at any time.

---

## 0. The one-paragraph answer

**There is ONE network CIDR, not two.** It is the Docker `kind` bridge network, `172.18.0.0/16`
(gateway `172.18.0.1`). It plays the part of the physical LAN — the switch the servers plug into.
Out of that one subnet **two address ranges are reserved** for Cilium to hand out as LoadBalancer
addresses, defined as two `CiliumLoadBalancerIPPool` objects:

| Range | Pool | Reserved for | Selector |
|---|---|---|---|
| `172.18.255.200 – 172.18.255.239` (40) | `kind-docker-pool` | ordinary `type: LoadBalancer` Services (Hubble UI, anything you expose directly) | `io.cilium.gateway/owning-gateway` **DoesNotExist** |
| `172.18.255.240 – 172.18.255.250` (11) | `gateway-pool` | **Cilium Gateway API only** — every `Gateway` lands here; wildcard DNS `*.poc.local` points into this range | `io.cilium.gateway/owning-gateway` **Exists** |

Both ranges sit inside the same `/16`, on the same L2 segment as the nodes. That is why **one
route on the Mac covers everything** (`172.18.0.0/16 → 192.168.64.2`) and why on a Linux server
**no route is needed at all** — the host is already on that segment.

If someone asks "one CIDR or two?", the precise sentence is: *one subnet (`172.18.0.0/16`), from
which the nodes take addresses at the bottom (`.0.2`, `.0.3`, …) by Docker's IPAM, and two reserved
service ranges at the top (`.255.200–239` and `.255.240–250`) by Cilium's IPAM.*

---

## 1. The layers, and what each one is in a real data centre

The PoC simulates four layers that exist in any on-prem network. Reading top-down: a client on the
laptop, a router, a switch/LAN, servers on that LAN, and services that float across those servers.

| Layer | In a real data centre | In this PoC | Created by |
|---|---|---|---|
| **4. Service addresses (VIPs)** | Addresses that belong to a *service*, not to one server. Announced by the servers via ARP on the LAN (L2), or via BGP to the router (L3). Move when a server dies. **Each cluster owns its own block of the VIP range** — clusters share the LAN, never an address. | the reserved `172.18.255.0/24`, one /26 per cluster: poc1 `.192/26` (`.200–250`), poc2 `.128/26` (`.136–186`), each announced by whichever of ITS nodes holds the Cilium L2 lease | Cilium LB IPAM + `CiliumL2AnnouncementPolicy`, one file per cluster (`cilium/lb-ippool-poc1.yaml`, `cilium/lb-ippool-poc2.yaml`) |
| **3. Servers (NICs on the LAN)** | Bare-metal or VMware hosts, each with a NIC plugged into the access switch, addresses from the LAN's DHCP/static plan | kind nodes = Docker containers, each with `eth0` on the bridge: `172.18.0.2 … .0.10` | `kind create cluster` (Docker allocates from the bottom of the subnet) |
| **2. The LAN / switch** | A VLAN on the access switch, e.g. `10.50.20.0/24`, with the router's interface as `.1` | Docker bridge network `kind` = `172.18.0.0/16`, Linux bridge `br-e1180494aacf`, gateway `172.18.0.1` | `docker network create kind` (kind does it for you the first time) |
| **1. The router / the client's path in** | The core/distribution router with a route to the VLAN; the client's laptop on a different network reaches the VLAN *through* it | **macOS:** the Mac is the router, next hop is the Docker VM (`192.168.64.2` over `bridge100`). **Linux:** the host *is* the router, it holds `172.18.0.1` on the bridge itself | `sudo route -n add …` (macOS); nothing (Linux) |

The point to make to the network team: nothing about this is a "kind trick". The service ranges are
carved from the LAN's subnet exactly as you would reserve a block of a VLAN for VIPs; the nodes
answer ARP for them exactly as keepalived/MetalLB/a hardware LB would in L2 mode; and the client's
route into the LAN is an ordinary static route on the nearest router. In production the only
substitution is layer 4's announcement method: **BGP (Cilium BGP control plane) to the router
instead of L2 ARP** — see §7.

---

## 2. ASCII diagram — the whole path, as measured

```
                        THE CLIENT AND ITS ROUTER
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  macOS host (your MacBook)                                                    │
 │                                                                              │
 │   curl https://web.poc.local  ──►  /etc/hosts: web.poc.local = 172.18.255.240 │
 │                                            │                                 │
 │   routing table:  172.18/16  via 192.168.64.2  dev bridge100  (UGSc, STATIC)  │
 │                                            │                                 │
 │   bridge100  192.168.64.1/24  ─ member vmenet0 ─┐                             │
 └─────────────────────────────────────────────────┼─────────────────────────────┘
                                                   │  192.168.64.0/24  (host <-> VM link,
                                                   │   exists only with kernelForUDP=true)
 ┌─────────────────────────────────────────────────┼─────────────────────────────┐
 │  Docker Desktop Linux VM  (= a Linux server running dockerd; ip_forward = 1)  │
 │                                                                              │
 │   eth1  192.168.64.2/24   ◄── the Mac's next hop                               │
 │     │   route: 192.168.64.0/24 dev eth1 scope link                            │
 │     │   route: 172.18.0.0/16   dev br-e1180494aacf scope link src 172.18.0.1  │
 │     ▼                                                                        │
 │   br-e1180494aacf  172.18.0.1/16      ◄── THE "SWITCH" / LAN (docker network  │
 │   ══╤═══════╤════════╤════════╤════════╤════════╤════════╤═══════╤═══════   │      "kind")
 │     │       │        │        │        │        │        │       │           │
 │  .0.2    .0.3     .0.4     .0.5     .0.6     .0.7     .0.8    .0.9   .0.10    │
 │  poc1-   poc1-    poc1-    poc1-    poc1-    poc1-    hubble  poc2-  poc2-    │
 │  ext-LB  cp3      worker2  worker   cp       cp2      -proxy  worker cp       │
 │  (envoy)   ▲                          ▲                                       │
 │            │ holds L2 lease for       │ holds L2 lease for                    │
 │            │ 172.18.255.240 (routes-gw)   172.18.255.201 (hubble-ui)          │
 │            │ 172.18.255.241 (sw-gateway)                                      │
 │            │  answers ARP: 172.18.255.240 is-at 02:42:ac:12:00:03             │
 │                                                                              │
 │   RESERVED SERVICE RANGES (same subnet, top of the /16):                      │
 │     172.18.255.200–239  kind-docker-pool   plain LoadBalancer Services        │
 │     172.18.255.240–250  gateway-pool       Cilium Gateway API ONLY            │
 │                         └─ *.poc.local, exact.example.test → .240 (routes-gw) │
 │                         └─ deathstar.poc.local             → .241 (sw-gateway)│
 └──────────────────────────────────────────────────────────────────────────────┘

 Inside a kind node (any of them), the same LAN seen from a server's NIC:
     default via 172.18.0.1 dev eth0
     172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.5

 ON A LINUX SERVER the top box disappears: the host IS the middle box. Its bridge holds 172.18.0.1
 and everything in 172.18/16 is on-link — no route to add.
```

Each line in that diagram maps to a command in §4 (macOS) or §5 (Linux) that prints it.

---

## 2b. A second LAN — poc3 on its own docker network

Demo 11 adds a third cluster (`poc3`, kindnet + kube-proxy) and it does **not** join the `kind`
network. It gets its own bridge, exactly as you would give a test rack its own VLAN:

```
 docker network create --subnet 172.30.0.0/16 --gateway 172.30.0.1 kind-classic
 KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-classic kind create cluster --config clusters/poc3.yaml
```

| | `kind` (poc1, poc2) | `kind-classic` (poc3) |
|---|---|---|
| subnet / gateway | `172.18.0.0/16` / `172.18.0.1` | `172.30.0.0/16` / `172.30.0.1` |
| bridge in the VM | `br-e1180494aacf` | `br-49634ac72e11` |
| nodes (measured) | `.0.2 … .0.10` | `.0.2` worker2, `.0.3` worker, `.0.4` control-plane |
| route on the Mac | `sudo route -n add -net 172.18.0.0/16 192.168.64.2` | `sudo route -n add -net 172.30.0.0/16 192.168.64.2` |
| pod / service CIDR | `10.10/16`, `10.11/16` (poc1) | `10.30/16`, `10.31/16` |

Why it matters beyond tidiness: a stopped kind node releases its address, and Docker hands the
lowest free address to whatever starts next. Had poc3 been created on `kind` while poc1 was
stopped, it would have taken `.2–.4` and poc1 could never have come back (gotcha #6). On its own
network it cannot collide, and `scripts/cluster-pause.sh` / `cluster-resume.sh` (which start
containers in ascending recorded-IP order) make stopping and resuming clusters safe — measured on
poc2 (both nodes back on `.9`/`.10`, Ready in 10 s) and on poc1 (six containers, all addresses
reproduced).

The Mac needs the second route only to reach poc3's services from a browser; none of demo 11's
measurements run from the Mac, so it is optional there.

The same pattern gave demo 13 a throwaway `poc4` on `kind-lab` (`172.31.0.0/16`), deleted with
its network afterwards — one network per cluster is the rule now.

## 3. The addressing plan (live, and how to reprint it)

Run this any time; it reads everything from Docker and the cluster, nothing is hardcoded:

```bash
scripts/network-plan.sh
```

Captured 2026-09-11:

```
================================================================================
 1. THE 'PHYSICAL' NETWORK — docker bridge 'kind' (the switch + the LAN)
================================================================================
  subnet  172.18.0.0/16   gateway 172.18.0.1
  subnet  fc00:f853:ccd:e793::/64   gateway fc00:f853:ccd:e793::1
  bridge interface (inside the Docker VM / on a Linux host): br-e1180494aacf

================================================================================
 2. THE 'SERVERS' — kind nodes attached to that bridge (addresses from docker IPAM)
================================================================================
  poc1-external-load-balancer      172.18.0.2/16
  poc1-control-plane3              172.18.0.3/16
  poc1-worker2                     172.18.0.4/16
  poc1-worker                      172.18.0.5/16
  poc1-control-plane               172.18.0.6/16
  poc1-control-plane2              172.18.0.7/16
  hubble-ui-proxy                  172.18.0.8/16
  poc2-worker                      172.18.0.9/16
  poc2-control-plane               172.18.0.10/16

================================================================================
 3. RESERVED SERVICE RANGES — LB IPAM pools carved from the SAME subnet
================================================================================
  POOL             START            STOP             SELECTOR                           OP             CONFLICT   AVAIL
gateway-pool       172.18.255.240   172.18.255.250   io.cilium.gateway/owning-gateway   Exists         False      9
kind-docker-pool   172.18.255.200   172.18.255.239   io.cilium.gateway/owning-gateway   DoesNotExist   False      39

================================================================================
 4. WHO HOLDS WHICH ADDRESS — and which pool it came from
================================================================================
  NS          SERVICE                     ADDRESS          PINNED           GATEWAY-OWNED
default       cilium-gateway-sw-gateway   172.18.255.241   172.18.255.241   sw-gateway
kube-system   hubble-ui                   172.18.255.201   172.18.255.201   <none>
routes        cilium-gateway-routes-gw    172.18.255.240   172.18.255.240   routes-gw

================================================================================
 5. WHO ANSWERS ARP FOR EACH ADDRESS — L2 announcement leases (moves if a node dies)
================================================================================
  LEASE                                               ANNOUNCING-NODE
cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-control-plane3
cilium-l2announce-kube-system-hubble-ui               poc1-worker
cilium-l2announce-routes-cilium-gateway-routes-gw     poc1-control-plane3

================================================================================
 6. HOW THIS HOST REACHES IT
================================================================================
  macOS: containers live in a VM; the host needs ONE static route via the VM.
  host bridge to the VM : bridge100
  route to the subnet   : 172.18 via 192.168.64.2 dev bridge100
```

Three things to read off that output, because they are the design:

1. **Node addresses are not stable.** Docker allocates from the bottom in whatever order containers
   start, and a Docker restart reshuffles them (README finding #3). That is why nothing in this
   repo refers to a node by IP — Cilium gets `k8sServiceHost=poc1-external-load-balancer` (a DNS
   name), never `172.18.0.2`.
2. **Service addresses ARE stable**, because they are pinned: `lbipam.cilium.io/ips` on the
   Service (Hubble UI `.201`) or under `spec.infrastructure.annotations` on the Gateway (`.240`,
   `.241`; the metadata annotation does not propagate — gotcha #13). DNS points at these, so they
   must not move.
3. **The two ranges cannot overlap and cannot collide with nodes.** They start at `.255.200`; Docker
   would have to allocate ~65,000 containers before it reached them. If two pools overlapped,
   Cilium marks the later one `Conflicting` and allocates nothing from it — `CONFLICT False` on
   both is the check.
4. **Every cluster owns a block of its own — the VIP range is subdivided, not shared.** A cluster is
   a complete system before it joins any mesh, and its service addresses are part of that. All
   clusters announce on the SAME bridge, and LB IPAM allocates per cluster (one operator, one
   cluster; the [LB IPAM docs](https://docs.cilium.io/en/stable/network/lb-ipam/) describe no
   coordination between clusters), so one pool file applied to two clusters hands out the same
   address twice and both answer ARP for it. The reserved top `/24` is carved into `/26` blocks
   with one layout inside each — plain Services at base+8…+47, Gateways at base+48…+58:

   | Block | Cluster | Services pool | Gateway pool | File |
   |---|---|---|---|---|
   | `172.18.255.192/26` | poc1 | `.200–.239` | `.240–.250` | `cilium/lb-ippool-poc1.yaml` |
   | `172.18.255.128/26` | poc2 | `.136–.175` | `.176–.186` | `cilium/lb-ippool-poc2.yaml` |
   | `172.18.255.64/26` | poc3, when a third cluster exists | `.72–.111` | `.112–.122` | — |
   | `172.18.255.0/26` | shared VIPs — a pool present in every cluster that announces them | | | enhancement 002 |

   The CI lab creates the docker network with `--ip-range 172.18.0.0/17` (`scripts/lab-up.sh`), so
   Docker can never allocate a container address in the top half at all. This is the enterprise
   shape: one VIP VLAN, a block per cluster, DNS pointing into each block.

---

## 4. macOS — Docker Desktop + kind, step by step

On macOS the containers run inside a Linux VM. The Mac has **no route** to the container network
until you give it one, and it has nowhere to send that route until Docker Desktop has created the
host↔VM link. Order matters: **4.1 → 4.2 → (create the cluster) → 4.3 → 4.4**.

### 4.1 Prerequisite — enable the host↔VM link (`kernelForUDP`), BEFORE creating any cluster

This is SETUP Step 2.3b; it needs a Docker restart, and a Docker restart destroys a multi-node kind
cluster (Step 2.7). Do it first. Docker Desktop 4.26+ only:

```bash
defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString
```

```
4.27.2
```

GUI: **Docker Desktop → Settings → Resources → Network → "Enable kernel networking for UDP"**, then
Apply & restart. Or edit the settings file and restart Docker yourself:

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Group Containers/group.com.docker/settings.json'
d = json.loads(p.read_text()); d['kernelForUDP'] = True
p.write_text(json.dumps(d, indent=2)); print('kernelForUDP ->', d['kernelForUDP'])
"
```

```
kernelForUDP -> True
```

Proof it worked, after the restart — a `bridgeNNN` with a `vmenet` member exists on the Mac:

```bash
ifconfig | awk '/^bridge[0-9]+:/{b=$1} /member: vmenet/{print b; exit}'
```

```
bridge100:
```

(The number is assigned by macOS; Docker's own docs say `bridge101`, this machine got `bridge100`.
Never copy the number from a guide — README finding #1.)

### 4.2 Create the docker network (kind does this) and the cluster

kind creates the `kind` network on first use with a subnet Docker picks (`172.18.0.0/16` here).
There is nothing to do by hand, but **look at it**, because every later address derives from it:

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} gw {{.Gateway}}{{"\n"}}{{end}}'
```

```
172.18.0.0/16 gw 172.18.0.1
fc00:f853:ccd:e793::/64 gw fc00:f853:ccd:e793::1
```

If your subnet is not `172.18.0.0/16` (Docker picks the first free `172.x.0.0/16`), every
`172.18` below becomes your value — the pools in `cilium/lb-ippool-poc1.yaml` included.

Then create the cluster (SETUP Step 3). The nodes attach to the bridge and take addresses from the
bottom:

```bash
docker network inspect kind --format '{{range .Containers}}{{printf "%-32s" .Name}} {{.IPv4Address}}{{"\n"}}{{end}}' | sort -t. -k4 -n
```

```
poc1-external-load-balancer      172.18.0.2/16
poc1-control-plane3              172.18.0.3/16
poc1-worker2                     172.18.0.4/16
poc1-worker                      172.18.0.5/16
poc1-control-plane               172.18.0.6/16
poc1-control-plane2              172.18.0.7/16
```

### 4.3 The route — derive both halves, never type them from memory

The command has two values in it: the **destination** (the docker subnet) and the **gateway**
(the VM's address on the host↔VM link). Both are read from the system:

```bash
DOCKER_NET=$(docker network inspect kind --format '{{(index .IPAM.Config 0).Subnet}}')
BR=$(ifconfig | awk '/^bridge[0-9]+:/{b=$1} /member: vmenet/{print b; exit}' | tr -d ':')
HOST_IP=$(ifconfig "$BR" | awk '/inet /{print $2}')
VM_IP=$(arp -an -i "$BR" | awk -v h="$HOST_IP" '$2 != "("h")" {gsub(/[()]/,"",$2); print $2; exit}')
echo "destination = $DOCKER_NET"
echo "host bridge = $BR ($HOST_IP)"
echo "gateway     = $VM_IP"
echo "command     = sudo route -n add -net $DOCKER_NET $VM_IP"
```

```
destination = 172.18.0.0/16
host bridge = bridge100 (192.168.64.1)
gateway     = 192.168.64.2
command     = sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

Sanity rule: the host address and the gateway must be on the same `/24` (`192.168.64.1` and
`192.168.64.2`). If they are not, stop — you have the wrong bridge.

Now run the printed command **yourself** (it needs `sudo`; no script in this repo runs it for you):

```bash
sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

```
add net 172.18.0.0: gateway 192.168.64.2
```

**This route is not persistent.** It disappears on reboot (and when Docker Desktop restarts, since
the VM link goes away). Re-run it; `netstat -rn -f inet | grep 172.18` tells you whether it is there.

### 4.4 Verify — prove each layer, in order

**Layer 1, the route exists and points at the VM:**

```bash
netstat -rn -f inet | grep '^172.18'
route -n get 172.18.255.240 | grep -E 'gateway|interface'
```

```
172.18             192.168.64.2       UGSc            bridge100
    gateway: 192.168.64.2
  interface: bridge100
```

**Layer 1, the Mac does NOT ARP for the service address — it routes it** (this is what makes the Mac
"a router"; a host on the LAN would have an ARP entry, a router has a next hop):

```bash
arp -an | grep -c '172\.18\.'
```

```
0
```

**Layer 2, the VM forwards, and holds the bridge** (the VM is a Linux server running dockerd; this is
its real routing table):

```bash
docker run --rm --privileged --pid=host --net=host alpine sh -c \
  'nsenter -t 1 -n ip -4 route show | grep -E "172\.18|192\.168\.64"; echo ip_forward=$(nsenter -t 1 -n cat /proc/sys/net/ipv4/ip_forward)'
```

```
172.18.0.0/16 dev br-e1180494aacf scope link src 172.18.0.1
192.168.64.0/24 dev eth1 scope link src 192.168.64.2
ip_forward=1
```

**Layer 3, a node sees the LAN as on-link:**

```bash
docker exec poc1-worker ip -4 route show
```

```
default via 172.18.0.1 dev eth0
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.5
```

**Layer 4, a service address is answered on the LAN by ARP from the lease-holding node.** The honest
test is from a container that is *not* a Cilium node (a Cilium node resolves the VIP in its own eBPF
service map and never ARPs — see §6). `hubble-ui-proxy` is a plain `alpine/socat` container on the
bridge, i.e. "another server on the LAN":

```bash
docker exec hubble-ui-proxy sh -c 'wget -q -O /dev/null --header="Host: web.poc.local" http://172.18.255.240/ && echo GET ok; cat /proc/net/arp'
docker exec poc1-control-plane3 ip -br link show eth0
```

```
GET ok
IP address       HW type     Flags       HW address            Mask     Device
172.18.255.240   0x1         0x2         02:42:ac:12:00:03     *        eth0
eth0@if33        UP             02:42:ac:12:00:03 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

The MAC that answered for `172.18.255.240` is `poc1-control-plane3`'s — exactly the node the lease
table in §3 names. Kill that node and the lease, and the ARP answer, move to another.

**End to end from the Mac, both ranges through the one route:**

```bash
curl -s -o /dev/null -w 'http %{http_code} via %{remote_ip}\n' -H 'Host: web.poc.local' http://172.18.255.240/   # gateway-pool
curl -s -o /dev/null -w 'http %{http_code} via %{remote_ip}\n' http://172.18.255.201/                            # kind-docker-pool
traceroute -n -m 3 -q 1 -w 2 172.18.255.240
```

```
http 200 via 172.18.255.240
http 200 via 172.18.255.201
 1  192.168.64.2  1.302 ms      <- hop 1 is the VM: the Mac's next hop, i.e. the Mac routed it
 2  *                           <- silence: L2-announced VIPs answer ARP but not ICMP TTL-exceeded
```

### 4.5 Names — the DNS records, and the one file you edit by hand

The Gateway range is what the wildcard points at. In production this is a DNS zone record
(`*.poc.local A 172.18.255.240`); on the laptop it is `/etc/hosts`. The script prints, it never
writes:

```bash
scripts/hosts-entries.sh
```

```
172.18.255.240  hubble.poc.local web.poc.local anything-at-all.poc.local grpc.poc.local exact.example.test
172.18.255.241  deathstar.poc.local
172.18.255.201  hubble-direct.poc.local
```

Append those lines yourself (needs `sudo`; the script never writes the file), then verify one
layer at a time — resolver, then TLS + route, then browser:

```bash
sudo sh -c 'scripts/hosts-entries.sh >> /etc/hosts'       # or: scripts/hosts-entries.sh | sudo tee -a /etc/hosts
grep -c 'poc.local' /etc/hosts                             # 3 — fewer means the script could not reach the cluster
dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # drop the macOS resolver cache
dscacheutil -q host -a name hubble.poc.local               # ip_address: 172.18.255.240
curl -s --cacert docs/root-ca.crt -o /dev/null -w '%{http_code}\n' https://hubble.poc.local/   # 200
open https://hubble.poc.local
```

Note that
everything under `*.poc.local` sits in **`gateway-pool`** — the wildcard is on the Gateway API range
by design, so a new hostname needs a new `HTTPRoute`, never a new address.

---

## 5. Linux server — Docker + kind, step by step

On a Linux server there is no VM. `dockerd` creates the `kind` bridge **on the host's own kernel**,
gives the host `172.18.0.1` on it, and the whole `/16` is on-link. The host is the router *and* is
on the LAN. §4.1 and §4.3 do not exist here.

The evidence for this is already in §4.4 layer 2: the Docker Desktop VM *is* a Linux server running
dockerd, and `172.18.0.0/16 dev br-… scope link src 172.18.0.1` is the routing entry any Linux
Docker host has. The commands below are that same check, run on the host itself.

### 5.1 Create the cluster, then look at the bridge

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} gw {{.Gateway}}{{"\n"}}{{end}}'
BR="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
ip -4 addr show "$BR" | grep inet
ip -4 route show | grep '^172.18'
```

Expected shape:

```
172.18.0.0/16 gw 172.18.0.1
    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-e1180494aacf
172.18.0.0/16 dev br-e1180494aacf proto kernel scope link src 172.18.0.1
```

`scope link` on the host's own table is the whole story: there is no next hop, nothing to add.

### 5.2 Verify a service address from the host

```bash
curl -s -o /dev/null -w 'http %{http_code} via %{remote_ip}\n' -H 'Host: web.poc.local' http://172.18.255.240/
ip neigh show | grep 172.18.255
```

Expected shape:

```
http 200 via 172.18.255.240
172.18.255.240 dev br-e1180494aacf lladdr 02:42:ac:12:00:03 REACHABLE
```

On Linux the host **does** have an ARP entry for the VIP (contrast §4.4 layer 1 on the Mac): the
host is on the LAN, so it resolved the address by ARP and the lease-holding node answered.

### 5.3 Reaching it from *other* machines (this is where the real network design starts)

The Linux server holds `172.18.0.0/16` on an internal bridge; nobody else on your network has a
route to it. Two options, in order of how close they are to production:

| Option | What you do | Production analogue |
|---|---|---|
| **A. Static route on the client or its router** (mirror of §4.3) | On a colleague's machine: `sudo ip route add 172.18.0.0/16 via <server-LAN-IP>` (Linux) / `sudo route -n add -net 172.18.0.0/16 <server-LAN-IP>` (macOS). On the server: `sysctl -w net.ipv4.ip_forward=1` and allow forwarding in its firewall. | A static route on the distribution router pointing the VIP block at the cluster's L3 next hop |
| **B. Announce with BGP** | Enable Cilium's BGP control plane (`bgpControlPlane.enabled=true`), peer the nodes with your router in a `CiliumBGPClusterConfig`, and advertise the pool addresses with a `CiliumBGPAdvertisement` of `advertisementType: Service`, `service.addresses: [LoadBalancerIP]` (its `selector` can restrict it to, e.g., Gateway-owned Services). Names verified against the Cilium v1.20.1 CRDs — BGP is off in this PoC, so those CRDs are not installed here. | Exactly what you would do on bare metal/VMware: the nodes peer with the ToR/router and the VIP block is learned, not configured |

Option A is enough for a shared lab. Option B is the design conversation with the network team
(§7); it is not built in this PoC because a kind bridge has no router to peer with — measured: 0
listeners on TCP 179 in the Docker VM, `172.18.0.1:179` refuses. The plan to add one (an FRR
container on the `kind` network as the ToR, a third pool off the LAN so BGP is the only way in) is
parked in [docs/summary/BGP_FRR_PLAN.md](docs/summary/BGP_FRR_PLAN.md).

---

## 6. Why a Cilium node never ARPs for a service address (and why that matters for testing)

If you test "is the VIP on the LAN?" from **inside a kind node**, you get a `200` and **no ARP
entry** — which looks like the L2 announcement is not working. It is working; the node simply never
needed it. With kube-proxy replacement every node carries every LoadBalancer VIP in its own eBPF
service map, so a connection from the node's host namespace is translated locally and never leaves
as a packet to `172.18.255.240`:

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -E '172\.18\.255\.(240|201)'
```

```
18   172.18.255.201:80/TCP     LoadBalancer   1 => 10.10.3.2:8081/TCP (active)
46   172.18.255.240:80/TCP     LoadBalancer   1 => 127.0.0.1:10199/TCP (active)    <- Envoy, the Gateway listener
51   172.18.255.240:443/TCP    LoadBalancer   1 => 127.0.0.1:10199/TCP (active)
52   172.18.255.240:9000/TCP   LoadBalancer   1 => 10.10.3.97:7000/TCP (active)    <- TCPRoute backend
```

So the rule for proving layer 4: test from something that is **not** a Cilium node — the Mac (§4.4),
a Linux host (§5.2), or a plain container on the bridge (`hubble-ui-proxy`). Those are the "external
clients" the design is for.

---

## 7. What to tell the network team — the checklist

Take `scripts/network-plan.sh` output and this table into the meeting.

| Question they will ask | Answer, from this PoC | What changes in production |
|---|---|---|
| How many subnets do you need? | **One** LAN/VLAN for the nodes (`172.18.0.0/16` here). | One node VLAN per cluster, sized for nodes + a reserved VIP block. |
| Where do LoadBalancer addresses come from? | **Two reserved ranges inside that subnet**: `.255.200–239` for plain Services, `.255.240–250` for Gateway API (ingress). Cilium's own IPAM allocates; no MetalLB, no kube-vip. | Same: reserve two blocks (or a separate VIP subnet if you prefer routed VIPs), give them to Cilium as `CiliumLoadBalancerIPPool`s. Ask for them to be **excluded from DHCP** and from any other allocation. |
| Why two ranges, not one? | Ingress (Gateway API) gets its own block so a **wildcard DNS record** can point at it and so the selector guarantees a Gateway never takes an address meant for a plain Service (and vice-versa). | Same. The wildcard zone (`*.apps.example.com`) points into the Gateway block only. |
| How does traffic reach a VIP? | **L2**: the node holding the Cilium lease answers ARP for it on the node VLAN; a client on another network needs a route to the VLAN (the Mac's static route). | **L3/BGP** preferred: nodes peer with the ToR/router via Cilium BGP control plane and advertise the VIP blocks. L2 is acceptable when clients and nodes share a VLAN. |
| What happens when a node dies? | The lease moves to another node within the lease timeout and it starts answering ARP (gratuitous ARP). Measured leases: `.240/.241` on `poc1-control-plane3`, `.201` on `poc1-worker`. | BGP withdraws/re-advertises the route; convergence is the router's timers. |
| Do node IPs need to be static? | **No, and this PoC deliberately depends on nothing being tied to a node IP** (Docker reshuffles them). Cilium is pointed at a DNS name for the API server. | Nodes usually get static/reserved DHCP; still, point everything at names. |
| Are service addresses static? | **Yes** — pinned per Service/Gateway, and DNS points at them. | Yes; the DNS zone is the contract. |
| Is there a second CIDR for the mesh (poc2)? | **No.** poc2's nodes sit on the *same* `172.18.0.0/16` (`.0.9`, `.0.10`). ClusterMesh needs node-to-node reachability and non-overlapping **pod/service** CIDRs (`10.10/10.11` vs `10.20/10.21`), not a separate node network. | Clusters in different VLANs/sites just need routed node reachability between them. |
| What does the pod/service CIDR have to do with the LAN? | Nothing — `10.10.0.0/16` (pods) and `10.11.0.0/16` (services) are internal to the cluster (VXLAN overlay between nodes). They must be unique per cluster for ClusterMesh, and must not collide with anything routable the nodes talk to. | Same; register them in the IPAM system as "cluster-internal, not routed" unless you run native routing. |

---

## 8. Where this is used in the rest of the repo

| Topic | Where |
|---|---|
| Enabling `kernelForUDP`, and why it must precede cluster creation | `docs/SETUP.md` Step 2.3b, Step 2.7 |
| The route, derived value by value, with the failure modes | `docs/SETUP.md` Step 3.5 (3.5.1–3.5.5), and the no-sudo alternative 3.5b |
| The two LB IPAM pools and the L2 policy, with the API-version trap | `docs/SETUP.md` Step 8, `cilium/lb-ippool-poc1.yaml`, README finding #2 |
| Pinning a Gateway's address on the path that propagates | `docs/GOTCHAS.md` #13, `demos/09-routes/01-gateway.yaml` |
| Wildcard TLS + DNS into the Gateway range | `demos/09-routes/README.md`, `scripts/hosts-entries.sh` |
| Reprint the live plan | `scripts/network-plan.sh` |
| Parked: prove BGP with an FRR router (demo 11 plan) | `docs/summary/BGP_FRR_PLAN.md` |
| Cilium references | [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/), [L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/), [BGP control plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/) |
