# Demo 04 — Transparent encryption with WireGuard

## Summary context

**The problem.** Pod-to-pod traffic that leaves a node crosses the physical network in the clear.
On a shared or untrusted underlay — a rented datacentre VLAN, a cloud VPC shared with other teams,
anything crossing an availability zone — anyone with a port mirror reads your service-to-service
traffic. The classic answer is a service mesh with mTLS, which means a sidecar per pod, a
certificate authority, rotation, and a per-request proxy hop.

**Cilium's answer.** Encrypt at the *node* level, in the kernel, with WireGuard. No sidecars, no
certificates, no application changes. Two Helm values turn it on.

**"Transparent" is literal here.** Applications are not modified, do not know it is on, and open
ordinary unencrypted sockets. Encryption happens below them as the packet leaves the node.

### Do I need to install WireGuard first? No.

This is the first question everyone asks. **WireGuard has been in the Linux kernel since 5.6**, and
Cilium drives it directly: it creates the `cilium_wg0` device, generates each node's keypair, and
distributes public keys through the `CiliumNode` CRD. There is nothing to install, no config file
to write, and **no peers to pair by hand**.

Check your kernel supports it before enabling — the last command is definitive:

```bash
docker exec poc1-worker uname -r
```

```
6.6.12-linuxkit
```

```bash
docker exec poc1-worker sh -c 'ls /sys/module/wireguard >/dev/null 2>&1 && echo IN-KERNEL || echo absent'
```

```
IN-KERNEL
```

> Note it is **absent from `/proc/modules`** — that lists *loadable* modules, and here WireGuard is
> built in. `/proc/modules` being empty of it proves nothing either way, which is why the next test
> matters.

```bash
docker exec --privileged poc1-worker sh -c 'ip link add wgtest type wireguard && echo SUCCESS && ip link del wgtest'
```

```
SUCCESS: kernel supports wireguard
```

If that fails, this feature cannot work — and Cilium will report it rather than silently sending
plaintext.

---

## Part 1 — enable and configure

Baseline first, so the change is visible:

```bash
docker exec poc1-worker sh -c 'ip link show | grep -c cilium_wg0 || echo 0'
```

```
0
```

The whole configuration, in `cilium/values-poc1.yaml`:

```yaml
encryption:
  enabled: true
  type: wireguard
```

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  -f cilium/values-poc1.yaml \
  --set k8sServiceHost=poc1-external-load-balancer --set k8sServicePort=6443
kubectl -n kube-system rollout restart daemonset/cilium
```

### Configuration options worth knowing

| Value | Default | What it changes |
|---|---|---|
| `encryption.enabled` | `false` | the master switch |
| `encryption.type` | `ipsec` | `wireguard` or `ipsec`. WireGuard needs no key secret and no key rotation job |
| `encryption.nodeEncryption` | `false` | also encrypt **host-network** traffic between nodes, not just pod traffic |
| `encryption.wireguard.persistentKeepalive` | `0` | keepalive interval, for peers behind NAT |

**`nodeEncryption` is the one to think about.** By default Cilium encrypts *pod* traffic; traffic
from a node's own host network (kubelet, etcd, the API server) is not. That shows up in the status
output below as `NodeEncryption: Disabled`, and it is a deliberate decision to revisit, not an
error.

## Part 2 — verify it is actually on

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i encryption
```

```
Encryption:  Wireguard  [NodeEncryption: Disabled, cilium_wg0 (Pubkey: 4rVB/OFsgc+3LQmlAwqzlhlKxP+K2Y850h1hkSeFLVg=, Port: 51871, Peers: 4)]
```

**`Peers: 4`** on a five-node cluster — every other node, discovered and paired automatically.

```bash
docker exec poc1-worker ip -d link show cilium_wg0
```

```
28: cilium_wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 65425 qdisc noqueue state UNKNOWN
    link/none
    wireguard numtxqueues 1 numrxqueues 1 ...
```

## Part 3 — PROOF: the traffic really is encrypted on the wire

Status output is a claim. This is the measurement.

`tiefighter` runs on `poc1-worker` (172.18.0.5); a `deathstar` replica runs on `poc1-worker2`
(172.18.0.4). Capture on the node's **physical** interface with a filter that would catch **either**
plaintext HTTP **or** WireGuard:

```bash
docker run -d --name wgcap --net=container:poc1-worker --privileged nicolaka/netshoot \
  timeout 30 tcpdump -i eth0 -nn -c 40 'host 172.18.0.4 and (udp port 51871 or tcp port 80)'
```

Generate six cross-node HTTP requests straight to the remote pod IP:

```bash
for i in $(seq 6); do
  kubectl exec tiefighter -- curl -s -o /dev/null -XPOST http://10.10.3.231/v1/request-landing
done
```

```bash
docker logs wgcap
```

```
05:54:46.381420 IP 172.18.0.4.51871 > 172.18.0.5.51871: UDP, length 144
05:54:46.593675 IP 172.18.0.5.51871 > 172.18.0.4.51871: UDP, length 144
05:54:46.596814 IP 172.18.0.5.51871 > 172.18.0.4.51871: UDP, length 240
05:54:46.601213 IP 172.18.0.4.51871 > 172.18.0.5.51871: UDP, length 304
...
```

**Read what is missing.** The filter accepted `tcp port 80` as well, and across six HTTP requests
**not one TCP/80 packet was captured.** Every packet is UDP on 51871 — WireGuard. The HTTP request,
the `Ship landed` response, the pod IPs: all inside the encrypted payload. An observer on that
network sees two nodes exchanging opaque UDP and nothing else.

## Part 4 — who is in the mesh, and who cannot get in

This is the question that matters for a security review: **membership**.

### Inside a node — the full peer list

```bash
docker run --rm --net=container:poc1-worker --privileged nicolaka/netshoot \
  sh -c 'apk add --no-cache wireguard-tools >/dev/null 2>&1; wg show cilium_wg0'
```

```
interface: cilium_wg0
  public key: 4rVB/OFsgc+3LQmlAwqzlhlKxP+K2Y850h1hkSeFLVg=
  private key: (hidden)
  listening port: 51871
  fwmark: 0xe00

peer: V7HRo+8aKSOly0j+vH3ETN9FIApSQE9we0FPW/76WH0=
  endpoint: 172.18.0.7:51871
  allowed ips: 172.18.0.7/32
  latest handshake: 42 seconds ago
  transfer: 1.36 KiB received, 1.25 KiB sent

peer: PWq3B6kfW31K7zxypNMuUolJDxdJhfGj4ueLYBbuo1c=
  endpoint: 172.18.0.4:51871
  allowed ips: 172.18.0.4/32
  latest handshake: 1 minute, 11 seconds ago
  transfer: 10.93 KiB received, 12.86 KiB sent
```

Four peers, one per other node, each with a live handshake and byte counters. **The mesh is exactly
the cluster's nodes** — membership comes from the `CiliumNode` CRD, so joining requires being a node
the Kubernetes API already admitted. There is no pre-shared key an outsider could obtain and no
endpoint to dial into.

### Outside — a client that cannot access `cilium_wg0`

The strongest version of this test: a container on **the very same L2 segment** as the nodes,
`172.18.0.9` on the kind docker bridge. It is as close to the cluster as an attacker on that
network could be.

```bash
docker run --rm --network kind --privileged nicolaka/netshoot sh -c '
  ip link show cilium_wg0 2>/dev/null || echo "NO cilium_wg0 - not in the mesh"
  ip -4 addr show eth0 | grep -o "inet [0-9.]*"
  curl -s -o /dev/null -m 5 -w "pod 10.10.3.231:80 -> %{http_code}\n" http://10.10.3.231/v1/request-landing
  curl -s -o /dev/null -m 5 -w "LB  172.18.255.201:80 -> %{http_code}\n" http://172.18.255.201/
'
```

```
NO cilium_wg0 - not in the mesh
inet 172.18.0.9
pod 10.10.3.231:80 -> 000        <- UNREACHABLE
LB  172.18.255.201:80 -> 200
```

| | Outsider on the same network |
|---|---|
| Has `cilium_wg0` | **no** — no device, no keypair, no peer entry |
| Reach a **pod IP** (`10.10.3.231`) | **no** — `000`, unreachable |
| Decrypt the captured UDP from Part 3 | **no** — it has none of the peers' private keys |
| Reach a **LoadBalancer** service (`172.18.255.201`) | **yes** — `200` |

That last row is the important nuance and should not be mistaken for a leak. WireGuard encrypts
**node-to-node pod traffic**. It is *not* a firewall for services you have deliberately published:
a `LoadBalancer` address exists precisely to be reached. **Encryption protects traffic in transit;
network policy controls who may talk to what.** They are different jobs, and demos 02 and 05 cover
the second. Turning on encryption does not narrow your published surface, and nobody should expect
it to.

## Use cases

| Situation | Why this helps |
|---|---|
| **Shared or untrusted underlay** | rented racks, a shared VPC, a provider you do not fully trust — the wire carries only ciphertext |
| **Cross-AZ / cross-datacentre traffic** | inter-AZ links are the most exposed hop and usually the least controlled |
| **Compliance: "encryption in transit"** | PCI-DSS, HIPAA and similar demand it; this satisfies it cluster-wide with two values and no per-app work |
| **You want mTLS-grade transit security without a service mesh** | no sidecar per pod, no CA, no cert rotation, no extra proxy hop |
| **Legacy apps that cannot do TLS** | the app is untouched and unaware; encryption happens beneath it |
| **Multi-tenant clusters** | one tenant capturing on a node cannot read another tenant's cross-node traffic |

### When it is *not* the right tool

- **In-cluster authorization** — that is network policy (demos 02/05), not encryption.
- **Protecting published services** — a LoadBalancer is public by design; see the table above.
- **Same-node pod-to-pod traffic** — it never touches the wire, so there is nothing to encrypt.
- **Per-request identity and authorization** — that is mTLS-with-SPIFFE territory; WireGuard
  authenticates *nodes*, not workloads.

## Cost

Encryption is not free — every cross-node packet is encrypted and decrypted. WireGuard is fast
(ChaCha20-Poly1305, in-kernel) but not zero. Demo 06 measures throughput with it on rather than
guessing, and states what that measurement does and does not prove on a laptop.

## Clean up

```bash
# turn encryption back off
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --reuse-values \
  --set encryption.enabled=false
kubectl -n kube-system rollout restart daemonset/cilium
docker rm -f wgcap
```
