# Enhancement 008 — the Colima lab: the same labs on a kernel that can say yes

The labs in this repository run on Docker Desktop's **linuxkit** kernel, and that kernel is the reason for
several standing caveats. The one with a WARN row of its own is TCP MD5: the fabric's `neighbor … password`
lines are configured, the kernel refuses `setsockopt(TCP_MD5SIG)`, and the sessions run unsigned while looking
authenticated (demo 46, `docs/REVIEW_DEMO46.md`). Gotcha #103 records the others — netkit, BIG TCP and the
bandwidth manager, all refused locally and exercised only in CI.

Colima runs an **Ubuntu** kernel in a Lima VM. Measured 2026-09-20 on this Mac:

| What | Measurement |
|---|---|
| Kernel | `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y` |
| A password on both sides | `Established` in 4 s, no `setsockopt` complaint in FRR's log |
| The wire, from inside the router's netns | **11 packets carrying a TCP-MD5 option** |
| A wrong password on one side | `Established → Idle → Connect`, still `Connect` after 30 s |
| Kernel counters while healthy | `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all `0` |

The negative control is the proof: an unsigned session shows zero failures too. Same FRR, same configs, a
different kernel, the opposite outcome — that is the whole reason this lab family exists.

## 0. What the two kernels actually offer

Measured 2026-09-20 on this Mac, reading each kernel's own config (`/proc/config.gz`). Docker Desktop's
linuxkit carries the *higher version number* and the *smaller feature set* — the options below are not
"newer kernel wins", they are what each build chose to include.

| Option | Docker Desktop `7.0.12-linuxkit` | Colima `6.8.0-117-generic` | What it is for here |
|---|---|---|---|
| `CONFIG_TCP_MD5SIG` | **absent** | `y` | signed BGP sessions — demo 46's standing WARN |
| `CONFIG_NETKIT` | **absent** | `y` | netkit devices (gotcha #103) |
| `CONFIG_NET_SCH_FQ` | **absent** | `m` | the fair queue rate limiting needs (gotcha #103) |
| `CONFIG_TCP_CONG_BBR` | **absent** | `m` | BBR, the congestion control that manager pairs with |
| `CONFIG_BPF_SYSCALL`, `CONFIG_DEBUG_INFO_BTF`, `CONFIG_CGROUP_BPF`, `CONFIG_NET_CLS_BPF` | `y` | `y`/`m` | eBPF and BTF — both fine |
| `CONFIG_WIREGUARD`, `CONFIG_XFRM_USER` | `y` | `m` | demo 04's encryption — both fine |
| `CONFIG_VXLAN`, `CONFIG_GENEVE`, `CONFIG_MACVLAN`, `CONFIG_IPVLAN`, `CONFIG_NF_TABLES`, `CONFIG_NET_SCH_HTB` | `y` | `m` | overlays, L2 modes, nftables, shaping — both fine |

Four options separate them, and every one is a networking feature this lab has wanted and been refused. That is
the technical case for running the BGP labs there; the resource footprint is the practical one.

## 1. Scope — the new BGP labs only

**Colima hosts the new BGP labs. Nothing else moves, now or later.** The operator, 2026-09-20: *"we only using
colima for now for our BGP labs… don't migrate old labs. just the new bgp labs."*

What runs on Colima:

| # | Lab | What it is |
|---|---|---|
| 46c | `demos/46-bgp-fabric-colima` | the four-router fabric, with TCP MD5 **enforced** instead of warned |
| 54c | `demos/54-eg-poc1-kube-vip-colima` | one kind cluster (`eg-poc1-colima` on `kind-eg-colima` `172.20.0.0/16`), kube-vip AS 65021. Door `10.198.0.10` in `10.198.0.0/26`. The Colima family has its own address space (P4 closed): Desktop keeps `172.19` / `10.98`. The Mac's gateway is the profile's vzNAT address `192.168.64.4`; the operator's line is `sudo route -n add -net 10.198.0.0/24 192.168.64.4` |
| 52c | `demos/52-eg-poc2-metallb-colima` | one kind cluster, MetalLB's FRR-K8s speaking BGP to that fabric |

What does not: **everything else**. Every existing lab — `poc1`/`poc2`, the vanilla Envoy Gateway clusters `eg-poc1`
and `eg-poc2`, the `bgp-fabric` project on port 8088, CRC — all stay on Docker Desktop, unchanged, and are not
scheduled to be migrated, folded together or retired. There is no stage in this plan that turns anything off.

The new labs use the **default CNI** — kindnet plus `kube-proxy`.

Why these labs and not the others: BGP is where the kernel decides the outcome. The fabric's `neighbor …
password` lines are enforcement on Ubuntu and decoration on linuxkit, and that difference is the point of the
demos, and of nothing else here.

## 2. Why one VM, and not two

The question that started this was whether the **existing** kind clusters on Docker Desktop could peer with a
fabric inside Colima. Measured:

- Both VMs sit on the same host bridge: Docker Desktop at `192.168.64.2`, the `md5lab` Colima profile at
  `192.168.64.3` (`colima start --network-address`), and the Mac reaches both (0.95 ms). The `bgp-fabric` profile
  had **no** such address until 2026-09-21 — it was created without the flag and had only Lima's user-mode
  `192.168.5.3`; a stop/start with `--network-address` gave it `192.168.64.4` (measured, no data lost).
- They **overlap in RFC1918 space**. From inside the Colima VM, `ping 172.19.0.3` answers in 0.19 ms — its own
  bridge, not Desktop's `kind-eg` node of the same address.
- Docker SNATs anything leaving a bridge, so a cross-VM session arrives from `192.168.64.2`, not from the node.
  `bgp listen range 172.19.0.0/17` matches nothing and every speaker looks like one peer.

Cross-VM peering is therefore possible only with two routes **and** a MASQUERADE exemption in each VM — plumbing
that exists solely to span two hypervisors, on a VM that hosts merged work. **Decision: the Colima family is
self-contained.** Its fabric and its clusters share one Docker context, exactly as the Desktop family does.

## 3. The shape

One profile, one context, one registry, one front door.

```
colima profile  lab                       → docker context colima-lab
compose project bgp-fabric-colima         the fabric
kind clusters   eg-poc1-colima            kube-vip     (kindnet + kube-proxy)
                eg-poc2-colima            MetalLB      (kindnet + kube-proxy)
registry        kind-registry             127.0.0.1:5001  (measured working: push from the Mac, catalog read back)
dashboard       127.0.0.1:8098            (8088 is the Desktop fabric's — they must not collide)
the Mac's route <VIP block> → the profile's vzNAT address (colima list → ADDRESS; 192.168.64.4 here)
```

### 3.1 Rules every script in the family obeys

1. **Never trust the active context.** Every daemon call is `docker --context "$CTX"`, and each script refuses —
   by name, before the first mutating call — to run against `desktop-linux`, `default` or another profile. A
   test proves the refusal creates nothing.
2. **Restore the context.** `colima start` switches the active context; an EXIT trap puts it back. A stray
   switch orphans the other lab — measured 2026-09-20, when a second lab's start took the dashboard's port and
   the Desktop fabric's dashboard exited mid-run.
3. **Bind only from `$HOME`.** Lima mounts `$HOME` (virtiofs) and nothing else; a `mktemp -d` config directory
   under `/var/folders` fails a bind mount with *"not a directory"* — measured.
4. **Create the profile with the flags that cannot change later.** `vmType` and `mountType` are fixed at
   creation and the disk can only grow (the operator's guide, *2 Years with Colima*):
   `--vm-type vz --mount-type virtiofs --mount-inotify --dns 8.8.8.8 --dns 8.8.4.4 --network-address`.
5. **Build once, push once.** Images go to `kind-registry` and the clusters pull from it — no `kind load`, no
   second copy to keep in step. `containerdConfigPatches` in each cluster config plus the standard
   `local-registry-hosting` ConfigMap.

### 3.2 Sizing

`cpu` and `memory` CAN be changed after creation (stop, edit, start); `vmType`, `mountType` and shrinking the
disk cannot. The family's target is the fabric (6 small routers), two kind clusters (4 nodes), a registry and
the images: **8 CPU / 16 GiB / 60 GiB** on a 64 GiB, 18-CPU Mac — alongside Docker Desktop, which keeps running the
other labs. Start smaller when running one lab at a time.

### 3.3 The front door

`scripts/colima-lab.sh up|down|status` runs the family in order — VM, registry, fabric, clusters — and prints
what an operator still has to do themselves (the `sudo route` line). Each layer keeps its own script
(`fabric-colima-up.sh`, `eg-colima-up.sh`, `colima-registry.sh`) so a reader can run one piece without the rest.

## 4. Prerequisites the pages must state

Docker Desktop provides the `docker` CLI **and** the `compose` / `buildx` plugins on this Mac; on a machine
without it they must come from Homebrew, or `docker-compose` works while `docker compose` does not:

```bash
brew install docker docker-compose docker-buildx colima kind
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx"   ~/.docker/cli-plugins/docker-buildx
```

(`$(brew --prefix)`, not `$HOMEBREW_PREFIX`, which only exists in shells that ran `brew shellenv`.)

## 5. What each lab must prove

| Lab | The rows that make it worth running |
|---|---|
| 46c | the kernel flag; the fabric converged; **packets carrying a TCP-MD5 option**; **a wrong password breaks the session and restoring it brings the session back**; the dashboard reading the routers over the management LAN |
| 54c | kube-vip peering from each node's own address on `172.20.0.0/17`; `4/4` SERVERS Established (both nodes × both leaves); door `10.198.0.10/32` in each leaf with a node next hop (AS 65021, ECMP); client0 `http_code=200` after the node return route; dashboard `server sessions 4/4 · external 2`; **the session signed** — `md5` option on every segment in both directions, and the negative control on the peer-group key; the VM route plus `DOCKER-USER` accept for `10.198.0.0/24`; the VIP answered from the Mac over `10.198.0.0/24 → 192.168.64.4` (`route in place http_code=200`, check `2026-09-21T00:36:14Z` 7 PASS) |
| 52c | the same for MetalLB's FRR-K8s speaker, including its own `BGPPeer`/`BGPAdvertisement` objects and `ServiceBGPStatus` |

Each lab carries the three pages of the `demo-guide` skill and its own `check.sh` whose exit is the FAIL count.

## 6. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Colima hosts the **new BGP labs only**; the existing labs stay on Docker Desktop and are not migrated | the operator, 2026-09-20 — BGP is where the kernel changes the outcome; nothing else needs it |
| D2 | One Colima profile (`lab`) for the BGP labs | the clusters and the fabric must share a Docker context to peer without NAT (§2) |
| D3 | Default CNI only — kindnet + kube-proxy | the operator, 2026-09-20 |
| D4 | A local registry instead of `kind load` | one build, one push, both clusters pull the same digest; measured working through Colima's port forwarding |
| D5 | The Mac reaches VIPs by a route to the profile's vzNAT address (`--network-address`; `192.168.64.4` here — `192.168.64.3` is `md5lab`'s), plus a `DOCKER-USER` accept in the VM, not by `extraPortMappings` | a port mapping cannot express one address per door; Docker 29's `FORWARD` policy drops what enters from outside a bridge (measured 2026-09-21) |
| D6 | MD5 is a FAIL row here, not a WARN | on this kernel it is enforceable, so an unsigned session is a defect rather than a platform limit |
