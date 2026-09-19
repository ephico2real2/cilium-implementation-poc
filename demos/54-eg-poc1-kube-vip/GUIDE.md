# Demo 54 — three things a reader does

Run from the repo root after `demos/54-eg-poc1-kube-vip/apply.sh`.
poc1 and poc2 are paused — do not resume them. No sudo is required
for the curls or grpcurl (`--resolve` and `-authority` do the name).
The hosts block is only for the real browser.

The Mac must have a route to `172.19/16` (gotcha
[#120](../../docs/GOTCHAS.md#120)). If `netstat -rn | grep 172.19` is
empty, every client on this machine times out while the cluster is
healthy:

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

## 1. Open the browser after the hosts block

```bash
demos/54-eg-poc1-kube-vip/hosts-entries.sh
```

Add the two lines to `/etc/hosts` (the script never writes the file).
Recorded (third apply):

```text
# ---- cilium-kind-poc demo54 (generated 2026-09-19T14:18Z by demos/54-eg-poc1-kube-vip/hosts-entries.sh) ----
172.19.255.100  api.eg-poc1.poc.local
172.19.255.101  grpc.eg-poc1.poc.local
# ---- end cilium-kind-poc demo54 ----
```

Then open `http://api.eg-poc1.poc.local/orders`.

*Expect:* the shop's `/orders` page — Chrome asks for `text/html` and
`jsonview` renders the three rows the third apply recorded
(`keyboard` 4999 ¢, `mouse` 1999 ¢, `monitor` 24900 ¢), served over
plain http (this door has no redirect). apply.sh already took a
headless screenshot of the same URL into `output/browser.png`
(`PNG image data, 1000 x 500`) using Chrome's
`--host-resolver-rules`, so `/etc/hosts` is not required for that
shot. `chrome_rc=124` is the 60 s timeout (gotcha #121), not a failed
page.

## 2. The curl pair

```bash
curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.100 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz

curl -s --resolve api.eg-poc1.poc.local:443:172.19.255.100 \
  --cacert .tmp/eg-poc1-root-ca.crt \
  -D - -o /dev/null https://api.eg-poc1.poc.local/healthz
```

*Expect:* both 200 and `X-Served-By: eg-poc1`. Recorded (third apply):

```text
http://api.eg-poc1.poc.local/healthz @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0
https://api.eg-poc1.poc.local/healthz @ 172.19.255.100:443 → 200 X-Served-By=eg-poc1 curl_rc=0
```

The HTTPS call verifies the leaf against `.tmp/eg-poc1-root-ca.crt`.
A bogus CA file fails the handshake.

## 3. The grpcurl pair

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 grpc.health.v1.Health/Check

go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -cacert .tmp/eg-poc1-root-ca.crt -authority grpc.eg-poc1.poc.local \
  172.19.255.101:443 grpc.health.v1.Health/Check
```

*Expect:* both print `{"status": "SERVING"}`. Recorded (third apply):

```text
{
  "status": "SERVING"
}
```

The `:authority` has to be `grpc.eg-poc1.poc.local`. The same call
aimed at the HTTP door (`172.19.255.100:80`) is the isolation line
apply.sh already recorded — exit 1, not SERVING. curl of `/healthz`
at the gRPC door is 404:

```text
isolation_grpcurl_rc=1
isolation_http_code=404 curl_rc=0
```

## Cleanup

`demos/54-eg-poc1-kube-vip/cleanup.sh` — the cluster stays;
kube-vip and the doors go. `scripts/eg-down.sh` deletes `eg-poc1`.
