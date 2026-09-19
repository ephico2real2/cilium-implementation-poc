# The network layers, in plain English — with the lab's examples

The operator, 2026-09-19: *"I sometimes mess up when talking about network layers. In simple English layer 1 to layer 7
with a bit technical if required."* This page is that answer, kept because it is the vocabulary every demo in this
repository uses. Think of a letter going through the post: each layer adds one thing the layer below does not know
about. Numbered from the bottom.

## Layer 1 — Physical

The wire, the fibre, the radio. Bits as electrical or light pulses. No addresses, no names. In the lab this is the
Mac's Wi‑Fi or Ethernet and, inside Docker, a virtual bridge (`kind`, `kind-eg`).

## Layer 2 — Data link (Ethernet)

Frames between machines on the **same** local network, addressed by **MAC address** (`36:20:3a:e4:50:8d`). **ARP** lives
here: *"who has IP 172.19.255.150? — tell me your MAC."* This is the layer kube-vip and MetalLB's "L2 mode" work at: one
node answers ARP for the door's address, so the bridge sends that node the frames. A switch is a layer 2 device.

Layer 2 does not cross routers. That is why the Mac's own ARP table never has a VIP: the Mac only reaches the Docker VM,
and the VM's bridge is where `arping` gets its three replies (demos 40, 51, 52, 54).

## Layer 3 — Network (IP)

Packets addressed by **IP address**, routed **between** networks. Routers, routes, subnets, CIDRs, BGP. The Mac's static
route `172.19.0.0/16 → 192.168.64.2` is a layer 3 decision: *"for that network, hand the packet to the VM."*
kube-proxy's rule *"traffic for 172.19.255.150 goes to pod 10.80.1.10"* is layer 3/4 plumbing. When MetalLB runs in BGP
mode (FRR) or Cilium runs BGP, the address is announced at **this** layer to a router instead of answered at layer 2 by
ARP — that is enhancement 006's lab.

## Layer 4 — Transport (TCP/UDP)

Ports and connections. TCP gives a reliable, ordered stream on a port (`:80`, `:443`, `:9090`); UDP just fires datagrams
(DNS). A Kubernetes `LoadBalancer` Service is really a layer 3+4 thing: an IP plus ports.

Two curl answers the demos record are layer 4 answers: **"connection refused"** (`curl` exit 7) means the address was
reachable but nothing listened on that port; **"timed out"** (exit 28) usually means nothing answered at layer 2/3 at
all — the missing Mac route in gotcha #120 looked exactly like that.

## Layers 5 and 6 — Session and presentation

In practice these blur into "the stuff between TCP and the application". **TLS** is the one that matters here: it sits
on top of TCP and below HTTP, and it is where the certificate, the SNI hostname (`--servername`), the CA verification
and the `-k` mistake live. When a reviewer said *"`--cacert` verified nothing because of `-k`"* (demo 51's review),
that was a layer 6 problem — the TCP connection (layer 4) was fine.

## Layer 7 — Application (HTTP, gRPC, DNS)

The protocol the program actually speaks. HTTP requests with a `Host` header and a path; gRPC, which is HTTP/2
underneath with `:authority`, a method path like `/shop.v1.Orders/GetOrder`, and metadata headers. This is where Envoy
Gateway and Cilium's Gateway do their work: an **HTTPRoute** matches hostname, path and header; a **GRPCRoute** matches
service, method and metadata; a "no route" answer is a layer 7 answer (`404`, or gRPC status 12 — demo 52's T8b).
Load balancing "by header" or "by method" only exists here.

## Where things live in the lab

| Thing | Layer | Why |
|---|---|---|
| ARP, MAC, "who answers for the VIP" | 2 | frames on the local bridge |
| kube-vip / MetalLB L2 mode, Cilium L2 announcements | 2 | they answer ARP |
| MetalLB BGP mode (FRR), Cilium BGP, the Mac's static route | 3 | routing between networks |
| Service IP + port, kube-proxy, "connection refused" | 3–4 | addresses and ports |
| TLS, certificates, SNI, CA verification | 5–6 (call it "TLS") | encryption above TCP, below HTTP |
| HTTPRoute, GRPCRoute, `X-Served-By`, 404, gRPC status codes | 7 | the application protocol |

## Two phrases people use loosely, made precise

- **"L4 load balancer"** — forwards TCP/UDP by IP and port without looking inside (kube-proxy, a `LoadBalancer`
  Service). **"L7 load balancer"** — reads the HTTP/gRPC request and routes on it (Envoy).
- **"The VIP moved at layer 2"** — a different MAC now answers ARP for the same IP. The IP (layer 3) never changed,
  which is exactly what the demos measure with `arping` before and after a move (demo 51's `eg-vip-move.sh`,
  demo 40's `vip-takeover.sh`).

## Where to read the measurements

- Layer 2 seen from Docker: [demo 54](../demos/54-eg-poc1-kube-vip/RECAP.md) (kube-vip puts the `/32` on the node's
  `eth0`) and [demo 52](../demos/52-eg-poc2-metallb/RECAP.md) (MetalLB answers ARP and adds nothing to the interface).
- Layer 3, the lab's routes and address plan: [NETWORKING_DESIGN.md](../NETWORKING_DESIGN.md),
  [docs/SETUP.md](SETUP.md).
- Layer 7 routing by method and metadata: demo 52's gRPC matrix; by hostname on Cilium: [demo 53](../demos/53-grpc-parity/RECAP.md).
