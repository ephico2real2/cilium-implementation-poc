# Demo 50 — the guide: exercises

Run from the repo root with eg1 and eg2 up (`scripts/eg-up.sh`). All three
exercises are read-only. poc1 and poc2 are paused — do not resume them; exercise
2 names what a Cilium cluster shows without waking it.

## Exercise 1 — read the channel annotations, then see what experimental would add

```bash
kubectl --context kind-eg1 get crd -o custom-columns=\
NAME:.metadata.name,\
CHANNEL:.metadata.annotations.gateway\\.networking\\.k8s\\.io/channel,\
BUNDLE:.metadata.annotations.gateway\\.networking\\.k8s\\.io/bundle-version \
  | grep -E 'NAME|gateway.networking.k8s.io'

# do not apply this — it is the mix the lab refuses (phase 0, 2026-09-18 21:05 UTC)
helm template probe-exp oci://docker.io/envoyproxy/gateway-crds-helm --version v1.9.1 \
  --set crds.envoyGateway.enabled=true --set crds.gatewayAPI.enabled=true \
  | grep -E 'channel: (standard|experimental)' | sort | uniq -c
```

*Expect:* every live `gateway.networking.k8s.io` CRD on eg1 is `channel:
standard`, `bundle-version: v1.6.2` (ten rows). The template with
`crds.gatewayAPI.enabled=true` emits the mix this lab avoids: **13 ×
`channel: experimental`, 2 × `standard`** (phase 0, rendered, not inferred).
That is why the guide installs upstream's `standard-install.yaml` and tells
the CRD chart `crds.gatewayAPI.enabled=false`. Do not apply the template.

## Exercise 2 — compare `helm list` with what a Cilium cluster has

```bash
helm list -n envoy-gateway-system --kube-context kind-eg1
kubectl --context kind-eg1 get crd | grep -E 'envoyproxy|gateway.networking' | wc -l
```

On a Cilium cluster (poc1/poc2 — **paused; do not start them**) the same two
commands print an empty Helm list in `envoy-gateway-system` (the namespace
does not exist) and **zero** `gateway.envoyproxy.io` CRDs. Cilium implements
Gateway API without a vendor CRD set; the ten standard CRDs on poc1 came from
`scripts/gateway-api-crds.sh`, not from a controller chart. The contrast is
the point: Envoy Gateway owns eight implementation CRDs (`EnvoyProxy`,
`BackendTrafficPolicy`, …); Cilium's implementation objects are Cilium CRDs
already on the cluster.

`helm list` on eg1 shows **`eg` only**. `eg-crds` is not a release — Helm
refused to store it (`Secret … Too long: may not be more than 1048576 bytes`,
recorded in the transcript). The eight CRDs are still there.

## Exercise 3 — read the two clusters' root fingerprints

```bash
for ctx in kind-eg1 kind-eg2; do
  echo "-- $ctx"
  kubectl --context "$ctx" -n cert-manager get secret eg-root-ca \
    -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -issuer -fingerprint -sha256
done
openssl x509 -in .tmp/eg-root-ca.crt -noout -fingerprint -sha256
```

*Expect:* `subject=CN=eg-root-ca`, `issuer=CN=eg-root-ca`, and the same
SHA-256 fingerprint on eg1, on eg2, and in `.tmp/eg-root-ca.crt`:

```text
sha256 Fingerprint=6A:37:32:53:17:91:45:80:66:4D:9F:0B:6B:05:59:64:43:16:BA:05:93:0E:0F:CD:7C:70:87:F8:C0:2B:67:16
```

The file is gitignored (issue #60). A committed PEM would be a different
certificate after the next `eg-down.sh` / `eg-up.sh`.

## Cleanup

`demos/50-eg-clusters/cleanup.sh` calls `scripts/eg-down.sh` — eg1, eg2 and
`kind-eg` only.
