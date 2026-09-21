# How we know this kernel signs: the throwaway VM, and what it measured

This lab exists because Docker Desktop's kernel cannot enforce TCP MD5 and an Ubuntu kernel can. That claim was
not taken from a config flag — it was measured in a **throwaway Colima profile called `md5lab`**, created for
this one question and deleted afterwards. This page is its record, kept because the demo's central claim rests
on it.

Why a separate VM at all: the question had to be answered without touching the running labs. A scratch profile
is its own Docker context, so nothing it did could reach Docker Desktop's containers or the fabric.

## What was asked

1. Does the kernel carry `CONFIG_TCP_MD5SIG`?
2. If it does, is a BGP session actually **signed on the wire**, or merely configured?
3. Can a Colima VM be reached from the Mac at all — is a route like the Docker Desktop one possible?

A flag in a config file answers none of that. Zero MD5 *failures* answers none of it either: an unsigned session
also fails zero times. Only the wire and a deliberately wrong password decide it.

## What was run

```bash
colima start --profile md5lab --vm-type vz --cpu 2 --memory 4 --disk 20
colima ssh --profile md5lab -- sh -c 'uname -r; zcat /proc/config.gz | grep CONFIG_TCP_MD5SIG'
```

Then two FRR routers on one bridge inside that VM — AS 65001 and AS 65002, `neighbor … password lab-bgp` on
**both** sides — with the session state read from `vtysh`, the wire read by `tcpdump` from a netshoot container
sharing the router's network namespace, and the kernel's own counters read with `nstat`:

```bash
docker --context colima-md5lab run --rm --net container:md5-a nicolaka/netshoot:v0.16 \
  sh -c 'timeout 12 tcpdump -n -vv -i any tcp port 179 | grep -icE "md5"'
docker --context colima-md5lab exec md5-b vtysh -c 'conf t' -c 'router bgp 65002' \
  -c 'neighbor 10.90.0.2 password WRONG-PASSWORD'
```

## What it measured

| Question | Result |
|---|---|
| kernel | `6.8.0-117-generic`, **`CONFIG_TCP_MD5SIG=y`** |
| session, password on both sides | `Established` in **4 s**, no `setsockopt` complaint in FRR's log |
| the wire | **11 packets carrying a TCP-MD5 option** in a 12 s capture |
| kernel counters while healthy | `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all **0** |
| **negative control** — wrong password on one side only | `Established → Idle → Connect`, still `Connect` after **30 s** |
| a Mac-reachable VM address | `colima start --network-address` gave the VM `192.168.64.3`, pinged from the Mac at **0.95 ms** — the same host bridge Docker Desktop's VM sits on at `.2` |

The negative control is the proof. A session that keeps running with a mismatched key is not signed, whatever
the counters say; this one went down and could not come back until the key matched again.

## The Mac's path to the lab, and the commands that prove it

The scratch VM answered question 3 in the abstract; this is the working form, on the lab's own profile. The VM's
address comes from the profile, never from a note — `colima start --network-address` is what creates it, and
`scripts/fabric-colima-up.sh` passes that flag at creation.

```bash
colima list --json | python3 -c 'import json,sys; [print(json.loads(l)["address"]) for l in sys.stdin if l.strip() and json.loads(l)["name"]=="bgp-fabric"]'
```

```text
192.168.64.4
```

One route on the Mac points the lab's VIP block at that address. `route -n add` fails with `File exists` if the
prefix is already routed — delete it first, or use `route -n change`. The route does not survive a reboot.

```bash
sudo route -n add -net 10.198.0.0/24 192.168.64.4
```

```text
add net 10.198.0.0: gateway 192.168.64.4
```

Then the route table and the door itself, measured 2026-09-20:

```bash
netstat -rn -f inet | grep -E '^10\.198'
curl -s -o /dev/null -w '%{http_code}\n' http://10.198.0.10/
```

```text
10.198/24          192.168.64.4       UGSc            bridge100
200
```

Two URLs work from the Mac browser once that route exists:

| URL | What it serves |
|---|---|
| <http://10.198.0.10/> | the door — a LoadBalancer address announced into the fabric by kube-vip over a **signed** BGP session, routed Mac → `192.168.64.4` → leaf → node |
| <http://127.0.0.1:8098/> | the fabric's dashboard: four routers, six fabric sessions, and the cluster's nodes as external peers |

Retiring the old block is one line, since a prefix can point at one VM only:

```bash
sudo route -n delete -net 10.98.0.0/24
```

## Two mistakes it caused, kept here because they cost time

1. **The scratch VM's address was quoted as the lab's.** `192.168.64.3` belongs to `md5lab`. The lab profile had
   been created *without* `--network-address` and had no reachable address at all, so a `sudo route …
   192.168.64.3` line published in these pages pointed at the wrong VM. The lab profile was restarted with the
   flag and is **`192.168.64.4`**; `scripts/fabric-colima-up.sh` now passes `--network-address` at creation and
   the scripts read the address from `colima list` instead of hard-coding it.
2. **The registry on `127.0.0.1:5001` was the scratch VM's**, not this lab's. Pushes still worked because the
   daemon resolves `localhost:5001` inside its own VM, but what the Mac saw came from `md5lab`. Deleting the
   profile (and its leftover SSH forwarder) left the lab's own registry — holding `door`, `kube-vip`,
   `kube-vip-cloud-provider` — as the only thing on that port.

## What happened to it

```bash
colima delete md5lab -f
```

Deleted 2026-09-20 once its three questions were answered, reclaiming 2 CPU / 4 GiB / 20 GiB and releasing the
port it had taken. Nothing in this lab depends on it; the numbers above are the only thing it left behind, and
the demo's own `check.sh` re-proves the same claim on the real fabric every run — the MD5 row with its own
negative control.

**A later, stronger result made it obsolete:** on this kernel **kube-vip signs too**. Docker Desktop's demo 56
recorded that kube-vip's gobgp "cannot set `TCP_MD5SIG`"; that was the kernel refusing the syscall, not a
library limit. Here the speaker carries the password, the sessions come up, and `tcpdump` in the leaf's
namespace counts the option in both directions.
