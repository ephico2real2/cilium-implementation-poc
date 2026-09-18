#!/usr/bin/env bash
set -euo pipefail; . scripts/bootstrap/versions-eg.env
helm template probe-exp oci://docker.io/envoyproxy/gateway-crds-helm --version "$ENVOY_GATEWAY_VERSION" \
  --set crds.envoyGateway.enabled=true --set crds.gatewayAPI.enabled=true 2>/dev/null | python3 -c '
import re, sys
docs = [d for d in re.split(r"^---\s*$", sys.stdin.read(), flags=re.M) if d.strip()]
exp_crd = std_non_crd = 0; bundles = set()
for d in docs:
    k = re.search(r"^kind: (.*)$", d, re.M)
    if not k: continue          # a "# Source:" comment-only document
    kind = k.group(1)
    ch = re.search(r"gateway\.networking\.k8s\.io/channel: (\S+)", d)
    bv = re.search(r"gateway\.networking\.k8s\.io/bundle-version: (\S+)", d)
    if bv: bundles.add(bv.group(1))
    if ch and ch.group(1) == "experimental" and kind == "CustomResourceDefinition": exp_crd += 1
    if ch and ch.group(1) == "standard" and kind != "CustomResourceDefinition": std_non_crd += 1
print("experimental CRDs", exp_crd, "standard non-CRDs", std_non_crd, "bundles", bundles)
sys.exit(0 if (exp_crd, std_non_crd, bundles) == (13, 2, {"v1.6.1"}) else 1)'
