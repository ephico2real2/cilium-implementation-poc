# Demo 50 — four things a reader reads

Run from the repo root after the lab is up. All four exercises are
read-only. poc1 and poc2 are paused — do not resume them.

## Prerequisites

- docker, kind `v0.33.0`, helm, and kubectl on the `PATH`.
- Both clusters already built (the up script for `eg1` and `eg2`):

```bash
scripts/eg-up.sh
```

- The Mac route is recorded in [RECAP.md](RECAP.md) *Prerequisites*;
  these exercises do not need it.

## Exercises

### 1. Inspect the reservation

Docker holds node addresses to the lower `/17` so the top `/24` cannot
become a node IP.

```bash
docker network inspect kind-eg --format \
  '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'
```

**Expect:** IPv4 `ip-range=172.19.0.0/17` inside `172.19.0.0/16`. The
IPv6 block has no `--ip-range`; inspect prints `invalid Prefix` there.

```text
subnet=172.19.0.0/16 ip-range=172.19.0.0/17 gateway=172.19.0.1
subnet=fc00:f853:ccd:e794::/64 ip-range=invalid Prefix gateway=fc00:f853:ccd:e794::1
```

### 2. Read the CRD channel labels

Every live `gateway.networking.k8s.io` CRD must be the standard channel
at the lab pin (D10). The assertion the up script records:

```bash
kubectl --context kind-eg1 get crd -o name | grep '\.gateway\.networking\.k8s\.io$' | while read -r crd; do
  ch=$(kubectl --context kind-eg1 get "$crd" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')
  ver=$(kubectl --context kind-eg1 get "$crd" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
  echo "$crd channel=$ch bundle-version=$ver"
done
```

**Expect:** ten rows, every one `channel=standard` and
`bundle-version=v1.6.2`.

```text
gateway.networking.k8s.io CRDs: 10 (want 10)
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io channel=standard bundle-version=v1.6.2
```

### 3. Compare the root fingerprint on both clusters

One CA, minted on `eg1`, copied to `eg2`. The PEM is
`.tmp/eg-root-ca.crt` (gitignored; issue #60).

```bash
for ctx in kind-eg1 kind-eg2; do
  echo "-- $ctx"
  kubectl --context "$ctx" -n cert-manager get secret eg-root-ca \
    -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -issuer -fingerprint -sha256
done
openssl x509 -in .tmp/eg-root-ca.crt -noout -fingerprint -sha256
```

**Expect:** `subject=CN=eg-root-ca`, `issuer=CN=eg-root-ca`, and the
same sha256 on `eg1`, on `eg2`, and in the PEM.

```text
subject=CN=eg-root-ca
issuer=CN=eg-root-ca
sha256 Fingerprint=6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
```

### 4. Run the check

```bash
demos/50-eg-clusters/check.sh
```

**Expect:** 27 PASS, 0 FAIL.

```text
== demo 50 — the vanilla lab's clusters (enhancement 007 phase 1)
demo 50 check: 0 FAIL
```

## Clean up

See [README.md](README.md) *Clean up*. That script calls the lab
teardown (`eg1`, `eg2`, `eg-poc1`, and `kind-eg` only):

```bash
scripts/eg-down.sh
```
