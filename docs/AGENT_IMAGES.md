# Which repository owns what, and which agent image is which

Three image names on one Docker daemon do the same job for two different labs.
Two of them are the same build; the third is unrelated to both. This is the
map, measured on the Colima VM on 2026-09-23.

## Where the code lives

| | repository | language |
|---|---|---|
| the fabric, the dashboard, the router agent | [ephico2real2/bgp-fabric](https://github.com/ephico2real2/bgp-fabric) | Go |
| this lab (demo 46 and everything that peers into it) | this repository | shell, Python |
| the forked teaching lab | [ephico2real2/bgp-lab-with-dashboard](https://github.com/ephico2real2/bgp-lab-with-dashboard) | Python |

This lab does not carry a copy of the first one. It builds it at a pinned
commit — `scripts/bgp-fabric.env` names the commit,
`scripts/bgp-fabric-fetch.sh` puts it on disk, and the image is stamped with
**that** commit rather than this repository's, because a sha from here would
name a tree that does not contain the code being built.

## What is on the machine

```text
$ docker --context colima-bgp-fabric images | grep -E "frr-agent|router-agent"
frr-agent:colima                                  326MB  created 2 days ago
frr-agent:local                                   310MB  created 7 hours ago
quay.io/ephico2real/bgp-router-agent:sha-65a3a48  310MB  created 5 hours ago
```

## Which container runs which

```text
bgp-fabric-colima-leaf1-1        frr-agent:colima
clab-simple-lab-isp1             frr-agent:local
```

## The table

| image | built from | language | runs in | published |
|---|---|---|---|---|
| `frr-agent:colima` | `bgp-fabric` (ours) | Go, 163 lines | our fabric, the `:8098` lab | no — built in the Colima VM |
| `frr-agent:local` | `bgp-lab-with-dashboard` (the fork) | Python, 330 lines | the fork's compose lab, `:8089` | no — built by `docker compose --build` |
| `quay.io/ephico2real/bgp-router-agent` | the fork | Python — **the same build as above** | the fork's containerlab path | yes, to Quay |

In `bgp-fabric` itself the same image is called `bgp-fabric-agent:local`. The
`:colima` tag is what this lab's scripts ask for, and it is a name for the
same build.

## The relationships, in one line each

- **`frr-agent:local` and `bgp-router-agent` are the same image.** Both come
  from `router-agent/Containerfile` in the fork. Two tags for two delivery
  paths: compose builds it locally and tags it `frr-agent:local`; CI builds it
  and pushes it as `bgp-router-agent` so `clab deploy` can pull rather than
  build.
- **`frr-agent:colima` is a different program.** Same design, different
  repository, different language, no shared code. It was written on 2026-09-20
  (`5f51082`) for demo 46; the fork's Python one was written on 2026-09-23
  (`965d085`) because the fork had no equivalent — it was still reaching
  routers through the host's Docker socket.

The contents differ visibly:

```text
frr-agent:colima  /usr/local/bin -> fabric-router-start  frr-agent
frr-agent:local   /usr/local/bin -> frr-agent  frr-agent-start  router-start
```

## What they all are

Every one of them is the **unmodified** upstream FRR image with a small
read-only HTTP service added:

```dockerfile
FROM quay.io/frrouting/frr:10.7.1     # untouched, same pin as before
COPY agent.py /usr/local/bin/frr-agent
```

FRR itself is not rebuilt, forked or patched in any of the three. What each
adds is an agent that answers a fixed list of `show` commands over HTTP on a
management address, so a dashboard can read a router **without holding the
host's Docker socket** — which is the whole machine, and was previously
mounted into a web page with no authentication.

`bgp-fabric`'s image says so in its own labels, so the claim is checkable
rather than asserted:

```text
org.opencontainers.image.base.name  quay.io/frrouting/frr:10.7.1
org.opencontainers.image.revision   cda9c7c11e204e0abeccc68441ae9e5a417c4a71
org.opencontainers.image.title      bgp-fabric-agent
```

## Why the names are bad

`frr-agent:local` (the fork, Python) is one word from `frr-agent:colima`
(ours, Go), on the same daemon, doing the same job for different labs.
Renaming the fork's local tag to `bgp-router-agent:local` would make the local
and published names match and stop it reading like a variant of ours.
