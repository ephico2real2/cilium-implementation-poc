#!/usr/bin/env python3
"""render.py — the platform's half of the blog's model: intent.yaml (what a developer declares) → CiliumNetworkPolicy
objects (what the platform enforces). One policy per component, ingress only, exactly the shape the blog shows
OpenChoreo rendering:
  * the component is selected by identity (its app label), so the policy follows it across reschedules;
  * `project` visibility admits endpoints of the cell — the namespace — in EVERY cluster the cell spans
    (`io.cilium.k8s.policy.cluster In [...]`; without it, `policy-default-local-cluster=true` makes the selector
    local-only and the mesh peer is denied — measured in Part 3, gotcha #62);
  * `external` visibility admits the platform gateway, Cilium's `ingress` identity;
  * http ports get `rules: {http: [{}]}` — allow everything, routed through Envoy so Hubble sees L7 (the blog's
    "L7 hook for observability");
  * everything else is denied because the policy exists.
Usage: render.py [--local-cluster-only] < intent.yaml > rendered/cell-policies.yaml   (apply to EVERY cluster)"""
import sys, yaml
local_only = '--local-cluster-only' in sys.argv
intent = yaml.safe_load(sys.stdin)
ns, clusters = intent['cell']['namespace'], intent['cell']['clusters']
def cell_selector():
    sel = {'matchLabels': {'io.kubernetes.pod.namespace': ns}}
    if not local_only:
        sel['matchExpressions'] = [{'key': 'io.cilium.k8s.policy.cluster', 'operator': 'In', 'values': clusters}]
    return sel
docs = []
for name, c in intent['components'].items():
    to_ports = [{'ports': [{'port': str(c['port']), 'protocol': 'TCP'}]}]
    if c.get('protocol') == 'http':
        to_ports[0]['rules'] = {'http': [{}]}
    ingress = []
    for v in c['visibility']:
        if v in ('project', 'namespace'):
            ingress.append({'fromEndpoints': [cell_selector()], 'toPorts': to_ports})
        elif v == 'internal':
            ingress.append({'fromEntities': ['cluster-mesh'], 'toPorts': to_ports})
        elif v == 'external':
            ingress.append({'fromEntities': ['ingress'], 'toPorts': to_ports})
        else:
            sys.exit(f'{name}: unknown visibility {v!r}')
    docs.append({'apiVersion': 'cilium.io/v2', 'kind': 'CiliumNetworkPolicy',
                 'metadata': {'name': f'cell-{name}', 'namespace': ns,
                              'labels': {'cell': ns, 'rendered-from': 'intent.yaml'},
                              'annotations': {'visibility': ','.join(c['visibility'])}},
                 'spec': {'description': f'{name}: rendered from intent.yaml (visibility={",".join(c["visibility"])}); do not edit',
                          'endpointSelector': {'matchLabels': {'app': name}}, 'ingress': ingress}})
print(f'# rendered by demos/19-zero-trust-cell/render.py from intent.yaml — {"LOCAL-CLUSTER ONLY (Part 3 experiment)" if local_only else "cluster-aware: " + ",".join(clusters)}\n# apply this SAME file to every cluster the cell spans')
print(yaml.safe_dump_all(docs, sort_keys=False))
