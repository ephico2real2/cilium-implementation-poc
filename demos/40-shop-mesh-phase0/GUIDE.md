# Demo 40 — the guide: exercises

Run from the repo root with poc1 and poc2 up and phase 0 applied (`demos/40-shop-mesh-phase0/apply.sh`).
Exercise 0 is `apply.sh` itself. The three below read from the live doors; exercise 1 writes the
VIP announcer (and writes it back).

## Exercise 1 — flip the VIP and watch `arp -n`

```bash
scripts/vip-takeover.sh --status
scripts/vip-takeover.sh poc2
arp -n 172.18.255.16
scripts/vip-takeover.sh poc1
```

*Expect:* `--status` says poc1, with `shop-vip-announce` present only there and
`lease holder=poc1-worker`. After `poc2`, the VIP lease is on a poc2 node (measured:
`poc2-control-plane`) and poc1's policy is gone. `arp -n 172.18.255.16` on this Mac has **no entry** —
the host route's next hop is the Docker VM, so the Mac never ARPs for the VIP. `curl -sk
--resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/` still returns 404
from whichever cluster now announces. Flip back to poc1 before leaving the exercise. A short gap
with no announcer is the price of never having two.

## Exercise 2 — request the VIP's leaf and read its SANs

```bash
echo | openssl s_client -servername api.shop.poc.local -connect 172.18.255.16:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

*Expect:* `issuer=CN=clustermesh-root-ca`, `subject=CN=api.shop.poc.local`, and three SANs:
`api.shop.poc.local`, `api.poc1.shop.poc.local`, `api.poc2.shop.poc.local`. Repeat against
`.242` with `-servername api.poc1.shop.poc.local` and `.177` with `api.poc2.shop.poc.local`:
same issuer, same three SANs — each cluster issued its own leaf from the same root. A wildcard
`*.shop.poc.local` would not have covered the two-label names.

## Exercise 3 — `shopctl probe` against a door that has no routes

```bash
demos/40-shop-mesh-phase0/hosts-entries.sh            # review; then sudo tee -a /etc/hosts
demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-darwin-arm64 \
  probe --url https://api.shop.poc.local --insecure
python3 demos/40-shop-mesh-phase0/client/python/shopctl.py \
  probe --url https://api.shop.poc.local -k
```

*Expect:* both clients print the same columns (`PATH STATUS X-SERVED-BY`) and three 404s (no
`X-Served-By` — no backend set it). Exit code 3: every path is a failed check. Without the hosts
lines, both print `000` (the name does not resolve; the clients have no `--resolve`). `check.sh`
uses `curl --resolve` so it does not depend on `/etc/hosts`. The doors exist; demo 41 is when a
path returns 200.

## Cleanup

`demos/40-shop-mesh-phase0/cleanup.sh` — doors, leaf, announcer, shared pool; namespaces kept.
