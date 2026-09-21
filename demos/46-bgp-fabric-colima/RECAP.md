# Demo 46 — a signed BGP fabric on a Colima kernel

This page brings up four FRR routers in Colima profile
`bgp-fabric` (context `colima-bgp-fabric`, project
`bgp-fabric-colima`). Docker Desktop runs a stripped linuxkit
kernel with no `CONFIG_TCP_MD5SIG`, so `setsockopt(TCP_MD5SIG)`
fails and the sessions run unsigned while the config says
otherwise — that is the WARN row demo 46 carries. Colima runs a
full Linux kernel in a Lima VM (and runs on both macOS and Linux);
here `6.8.0-117-generic` with `CONFIG_TCP_MD5SIG=y`, so the same
`neighbor … password` lines are enforced — this run's check
counted `md5-option packets=10/10 on 10.200.1.3` and a wrong password took the
session `Established→Idle`, down in 15/15 samples, then restored `Established`. The
throwaway VM that settled the flag, the wire, the wrong-key
control, and the Mac path is in
[KERNEL-EVIDENCE.md](KERNEL-EVIDENCE.md).

## What you get

- Apply `2026-09-21T02:58:09Z`. Four routers on
  `frr-agent:colima` / `quay.io/frrouting/frr:10.7.1` (AS 65000 /
  65100 / 65101 / 65102). Six sessions;
  `converged after 1 s (1 polls)`.
- `client0` reaches `10.200.255.1` / `.2` / `.11` / `.12`
  (`ttl=62`, 0% loss); hops `10.200.100.2 → 10.200.1.18 →
  10.200.255.11`.
- Kernel `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y`;
  `md5-option packets=10/10 on 10.200.1.3`;
  `Established→Idle, down in 15/15 samples; restored Established`.
- Mgmt `10.200.200.0/24` (`10.200.200.1`, `10.200.200.2`,
  `10.200.200.11`, `10.200.200.12`, `10.200.200.100`,
  `10.200.200.254`); not in BGP. Dashboard `127.0.0.1:8098`,
  `external=2`. Check `2026-09-21T02:58:46Z`: 17 rows, 0 FAIL;
  `client0_rc=28,28,28,28`. Mac path `192.168.64.4`;
  `http://10.198.0.10/` → `200`.

## Architecture

Four routers in one Colima VM, in RFC 7938 tiers. Every session below is **signed** — the password
lines are enforcement on this kernel, not intent.

```text
      MacBook                        Colima VM · profile bgp-fabric · Ubuntu 6.8.0-117-generic
  ┌───────────────┐             ┌───────────────────────────────────────────────────────────┐
  │ browser       │──── :8098 ──┼──────────────────────────────┐                            │
  │ curl 10.198.. │             │                              │                            │
  └───────┬───────┘             │        ┌───────────────┐     │   wan 10.200.100.0/24      │
          │                     │        │  client0      │     │                            │
   route 10.198.0.0/24          │        │ 10.200.100.10 │     │                            │
    via 192.168.64.4            │        └───────┬───────┘     │                            │
          │                     │                │ .2          │                            │
          └─────────────────────┼────────┐  ┌────┴─────┐       │                            │
                                │        └─▶│   edge   │ AS 65000   lo 10.200.255.1         │
                                │           └────┬─────┘                                    │
                                │        10.200.1.16/29   .19 ── .18                        │
                                │           ┌────┴─────┐                                    │
                                │           │  spine   │ AS 65100   lo 10.200.255.2         │
                                │           └──┬────┬──┘   maximum-paths 8                  │
                                │  10.200.1.0/29    10.200.1.8/29                           │
                                │      .3 ──┘        └── .11                                │
                                │   ┌───────┴──┐      ┌──┴───────┐                          │
                                │   │  leaf1   │      │  leaf2   │                          │
                                │   │ AS 65101 │      │ AS 65102 │                          │
                                │   │ lo ..11  │      │ lo ..12  │                          │
                                │   └────┬─────┘      └─────┬────┘                          │
                                │        └── SERVERS listen 172.20.0.0/17 ──┘                │
                                │            (no members in this demo — 54c brings them)     │
                                └───────────────────────────────────────────────────────────┘
```

The routers are managed on a second plane the data plane cannot reach. FORWARD drops transit onto it,
and INPUT drops the agent's port on every interface but `mgmt` and `lo`:

```text
   mgmt 10.200.200.0/24  (not in BGP, Docker bridge .254)
   ┌──────────┬──────────┬──────────┬──────────┐
   │ edge .1  │ spine .2 │ leaf1 .11│ leaf2 .12│   each :8080, allow-listed `show … json`
   └────┬─────┴────┬─────┴────┬─────┴────┬─────┘
        └──────────┴────┬─────┴──────────┘
                 ┌──────┴───────┐
                 │ dashboard    │ 10.200.200.100 → 127.0.0.1:8098
                 └──────────────┘
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| client0 | `10.200.100.10` | outside world, default via `10.200.100.2` | netshoot v0.16 |
| edge | lo `10.200.255.1`, wan `10.200.100.2`, link `10.200.1.19` | border, originates `10.200.100.0/24` | FRR AS 65000 |
| spine | lo `10.200.255.2`, links `10.200.1.3` / `.11` / `.18` | transit, `maximum-paths 8` | FRR AS 65100 |
| leaf1 | lo `10.200.255.11`, link `10.200.1.2` | ToR, SERVERS listen | FRR AS 65101 |
| leaf2 | lo `10.200.255.12`, link `10.200.1.10` | ToR, SERVERS listen | FRR AS 65102 |
| mgmt | `10.200.200.0/24` | out of band; not in BGP | Docker bridge `.254` |
| agents | `.1` `.2` `.11` `.12` on `:8080` | allow-listed `show … json` | `frr-agent` |
| dashboard | `10.200.200.100` → `127.0.0.1:8098` | live topology | `bgp-dashboard:colima` |
| VM | `192.168.64.4` | vzNAT from `colima list` | Mac next hop for `10.198.0.0/24` |

[enhancement 006](../../enhancements/006-bgp-tutorial.md).
[NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md).

## Prerequisites

Without Docker Desktop: the CLI, both plugins, and Colima. Use
`$(brew --prefix)`, not `$HOMEBREW_PREFIX`. Same lab on Linux
with Colima or plain Docker.

```bash
brew install docker docker-compose docker-buildx colima
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" \
  ~/.docker/cli-plugins/docker-compose
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" \
  ~/.docker/cli-plugins/docker-buildx
```

- Profile `bgp-fabric`: `vm-type vz`, `mount-type virtiofs`, 4
  CPU, 6 GiB, 40 GiB, DNS 8.8.8.8 / 8.8.4.4,
  `--network-address`. `vmType` / `mountType` frozen; disk grows
  only.
- Pin `FRR_IMAGE=quay.io/frrouting/frr:10.7.1` in
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env).
  Copy [`fabric/.env.example`](fabric/.env.example) to `.env`.
  Scripts refuse `desktop-linux`.

```bash
test -f scripts/bootstrap/versions-eg.env
test -f demos/46-bgp-fabric-colima/fabric/.env.example
```

## Steps

From the repo root:

### 1. Bring the fabric up

```bash
RECORD_STRICT=1 bash demos/46-bgp-fabric-colima/apply.sh
```

Result: `image frr-agent:colima present`;
`image bgp-dashboard:colima present`;
`converged after 1 s (1 polls)`; `dashboard ready after 0 s
(routers=4/4 sessions=6/6 external=2)`.

### 2. Read the routes on spine and edge

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T edge vtysh -c 'show ip bgp'
```

Result: `Displayed 5 routes and 5 total paths` on both.

### 3. Walk the path from the outside world

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Result: hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`;
`0% packet loss, time 2073ms`; `ttl=62`.

### 4. Read the servers' policy

The leaves listen on `172.20.0.0/17` only. Prefix-lists wait
for the next phase.

```bash
docker --context colima-bgp-fabric compose -p bgp-fabric-colima \
  -f demos/46-bgp-fabric-colima/fabric/compose.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
```

Result: `1 IPv4 listen range(s)` — `172.20.0.0/17`; no members;
no `ttl-security`.

### 5. Prove TCP MD5 is on the wire

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'echo "kernel=$(uname -r)"; grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

Result: `kernel=6.8.0-117-generic`; `CONFIG_TCP_MD5SIG=y`; check
`md5-option packets=10/10 on 10.200.1.3`.

### 6. Read the dashboard

```bash
curl -fsS --max-time 5 'http://127.0.0.1:8098/api/state' \
  | python3 scripts/fabric-dashboard-state.py
```

Result: `routers=4/4 sessions=6/6 external=2`. Apply clear:
`dashboard showed the drop after 0.62 s`; `dashboard confirmed
recovery after 0.68 s (polled after the screenshots)`;
`window=2.001 s`.

### 7. Route the VIP block from the Mac

Gateway from `colima list`. See
[KERNEL-EVIDENCE.md](KERNEL-EVIDENCE.md).

```bash
colima list --json | python3 -c 'import json,sys; [print(json.loads(l)["address"]) for l in sys.stdin if l.strip() and json.loads(l)["name"]=="bgp-fabric"]'
sudo route -n add -net 10.198.0.0/24 192.168.64.4
curl -s -o /dev/null -w '%{http_code}' http://10.198.0.10/
```

Result: `192.168.64.4`;
`add net 10.198.0.0: gateway 192.168.64.4`; `200`.

## Verify

```bash
colima ssh --profile bgp-fabric -- \
  sh -c 'grep -E "^CONFIG_TCP_MD5SIG=" /boot/config-$(uname -r)'
```

```bash
bash demos/46-bgp-fabric-colima/check.sh
```

Result: `CONFIG_TCP_MD5SIG=y`; 17 rows, 0 FAIL;
`md5-option packets=10/10 on 10.200.1.3`;
`Established→Idle, down in 15/15 samples; restored Established`;
`client0_rc=28,28,28,28`;
`demo 46-colima check: 0 FAIL`.

## Reference

| Item | Value |
|---|---|
| docker context | `colima-bgp-fabric` (scripts refuse any other name) |
| Colima profile | `bgp-fabric` — vz + virtiofs + `--network-address`; disk can only grow |
| compose project | `bgp-fabric-colima` |
| images | `frr-agent:colima`, `bgp-dashboard:colima` |
| dashboard | `127.0.0.1:8098` (`FABRIC_COLIMA_DASHBOARD_PORT`) |
| password | `FABRIC_BGP_PASSWORD` in `fabric/.env` (default `lab-bgp`) |
| last apply | `2026-09-21T02:58:09Z` |
| last check | `2026-09-21T02:58:46Z` |
| files | [README.md](README.md), [GUIDE.md](GUIDE.md), [NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md), [KERNEL-EVIDENCE.md](KERNEL-EVIDENCE.md) |

## Clean up

```bash
bash scripts/fabric-colima-down.sh
```

## What's next

- Next phase: attach a kind cluster —
  [demo 54-colima](../54-eg-poc1-kube-vip-colima/RECAP.md).
- [GUIDE.md](GUIDE.md). [NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md).
