# Demo 40 — six things to try

Six exercises against the demo once it is up; nothing here changes the
cluster except exercise 5 and the hosts block under Prerequisites.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- Both clusters up (Gateway API and L2 already on poc2).
- A route on the Mac to `172.18/16`.
- The hosts block — the one sudo step (the script only prints the lines;
  the `tee` writes them):

```bash
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Exercises

### 1. Read who announces the VIP

`--status` is read-only. The VIP lease name is
`cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw`.

```bash
scripts/vip-takeover.sh --status
```

**Expect:** poc1 announces, with `shop-vip-announce` present only there
and `lease holder=poc1-worker`. `arp -n` on this Mac has no entry.

```text
== VIP 172.18.255.16 announced by: poc1
-- poc1
  shop-vip-announce: present
  lease holder=poc1-worker
-- poc2
  shop-vip-announce: absent
  lease: none
== arp -n 172.18.255.16
172.18.255.16 (172.18.255.16) -- no entry
```

### 2. Call the three doors

404 is the pass mark: the door exists and no route is attached. 000
means unreachable.

```bash
curl -sk --resolve api.shop.poc.local:443:172.18.255.16 \
  -o /dev/null -w '%{http_code}\n' https://api.shop.poc.local/
curl -sk --resolve api.poc1.shop.poc.local:443:172.18.255.242 \
  -o /dev/null -w '%{http_code}\n' https://api.poc1.shop.poc.local/
curl -sk --resolve api.poc2.shop.poc.local:443:172.18.255.177 \
  -o /dev/null -w '%{http_code}\n' https://api.poc2.shop.poc.local/
```

**Expect:** `404` on each door.

```text
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16 answers                 http_code=404                                        http_code=404 in phase 0
  PASS   https://api.poc1.shop.poc.local @ 172.18.255.242 answers               404                                                  http_code=404 in phase 0
  PASS   https://api.poc2.shop.poc.local @ 172.18.255.177 answers               404                                                  http_code=404 in phase 0
```

### 3. Probe the VIP with both clients

The clients know only the URL — the hosts block resolves it (they have
no `--resolve`). `probe` hits `/healthz`, `/ready`, `/orders` once each.

```bash
demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-darwin-arm64 \
  probe --url https://api.shop.poc.local --insecure
python3 demos/40-shop-mesh-phase0/client/python/shopctl.py \
  probe --url https://api.shop.poc.local -k
```

**Expect:** both print `PATH STATUS X-SERVED-BY` and one row per path.
In phase 0 every STATUS is `404` with `-` for the header (no backend set
it) and the exit code is 3 — one per failed path (`runProbe` in
`client/go/shopctl/main.go`); once demo 41 is attached `/healthz` is
`200 poc1`. Without the hosts block both print `000`. Not in the
transcript: `apply.sh` does not record a probe.

### 4. Read the VIP's leaf

Each cluster issued its own leaf from the same root. Repeat against
`.242` with `-servername api.poc1.shop.poc.local` and `.177` with
`api.poc2.shop.poc.local`.

```bash
echo | openssl s_client -servername api.shop.poc.local \
  -connect 172.18.255.16:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

**Expect:** `issuer=CN=clustermesh-root-ca`,
`subject=CN=api.shop.poc.local`, and the three SANs. A wildcard
`*.shop.poc.local` would not have covered the two-label names.

```text
  PASS   VIP leaf issuer is clustermesh-root-ca                                 issuer=CN=clustermesh-root-ca                        openssl x509 -noout -issuer contains clustermesh-root-ca
```

### 5. Flip the VIP announcer (this changes the cluster)

Deletes `shop-vip-announce` from the other cluster first, then applies
it to the target. Flip back to poc1 before leaving; `check.sh` assumes
that.

```bash
scripts/vip-takeover.sh poc2
scripts/vip-takeover.sh --status
scripts/vip-takeover.sh poc1
```

**Expect:** after `poc2`, the VIP lease is on `poc2-control-plane` and
poc1's policy is gone. After 20 s the dying lease is gone. After `poc1`,
`lease holder=poc1-worker` again. A short gap with no announcer is the
price of never having two.

```text
== VIP 172.18.255.16 announced by: poc2
-- poc1
  shop-vip-announce: absent
  lease: none
-- poc2
  shop-vip-announce: present
  lease holder=poc2-control-plane
```

### 6. Run the check

```bash
demos/40-shop-mesh-phase0/check.sh
```

**Expect:** 21 PASS, 0 FAIL. The lease row names poc1.

```text
  PASS   exactly one cluster holds the VIP l2announce lease                     poc1 holder=poc1-worker                              lease cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw has a holderIdentity in one context, none in the other
```

## Clean up

[README Clean up](README.md#clean-up).
