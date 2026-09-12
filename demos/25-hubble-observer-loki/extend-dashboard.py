#!/usr/bin/env python3
"""extend-dashboard.py <in.json> <out.json> [--title-suffix " (extended)"]
Add two pie panels to the hubble-observer dashboard (grafana.com 23862 / the chart's dashboard/cilium-hubble-flows.json),
built from data every DROPPED flow already carries but no shipped panel shows (demo 25 Part 7c):
  - Flows per Drop Reason   : flow.drop_reason_desc (POLICY_DENIED = nothing allowed it, POLICY_DENY = an explicit deny rule)
  - Flows per Denying Policy: flow.egress_denied_by[0].name — Loki's json parser skips arrays, so the element is
                              extracted with the JSON-path form `| json denied_by="flow.egress_denied_by[0].name"`
Both use the dashboard's own variables and $logparser, are placed on a new row under the Statistics pies, and everything
below is pushed down. Idempotent: running it on an already-extended file changes nothing."""
import json, sys, copy
src, dst = sys.argv[1], sys.argv[2]
suffix = sys.argv[sys.argv.index('--title-suffix')+1] if '--title-suffix' in sys.argv else ''
d = json.load(open(src))
def find(ps, title):
    for p in ps:
        if p.get('title') == title: return p
        if p.get('panels'):
            r = find(p['panels'], title)
            if r: return r
if find(d['panels'], 'Flows per Drop Reason'):
    print("already extended; nothing to do"); json.dump(d, open(dst, 'w'), indent=1); sys.exit(0)
verdict = find(d['panels'], 'Flows per Verdict'); assert verdict, "template panel 'Flows per Verdict' not found"
container = d['panels'] if verdict in d['panels'] else next(p['panels'] for p in d['panels'] if p.get('panels') and verdict in p['panels'])
def walk(ps):
    m = 0
    for p in ps:
        m = max(m, p.get('id', 0))
        if p.get('panels'): m = max(m, walk(p['panels']))
    return m
maxid = walk(d['panels'])
sel = '{namespace="$hubbleobservernamespace",container="hubble-observer"} |~ `(?i)$searchregex` !~ `(?i)$excluderegex`'
common = ('| $logparser | flow_source_namespace=~"$sourcenamespace" | flow_destination_namespace=~"$destinationnamespace" '
          '| flow_traffic_direction=~"$direction" | flow_IP_ipVersion=~"$ipversion" | flow_source_cluster_name=~"$sourcecluster" '
          '| flow_destination_cluster_name=~"$destinationcluster"')
specs = [
    ('Flows per Drop Reason', 'flow_drop_reason_desc', '',
     'Cilium drop reason of each DROPPED flow (flow.drop_reason_desc): POLICY_DENIED = no rule allowed it, POLICY_DENY = an explicit deny rule.'),
    ('Flows per Denying Policy', 'denied_by', ' | json denied_by="flow.egress_denied_by[0].name" | denied_by!=""',
     "The policy that denied the flow (flow.egress_denied_by[0].name), filled by Cilium's policy correlation for explicit deny rules; Loki's json parser skips arrays, so the element is extracted by JSON path."),
]
new = []
for i, (title, by, extra, desc) in enumerate(specs):
    p = copy.deepcopy(verdict); p['id'] = maxid + 1 + i; p['title'] = title; p['description'] = desc
    p['targets'][0]['expr'] = f'sum by({by}) (\n    count_over_time(\n        {sel}\n        {common}{extra}\n    [$__range])\n)'
    p['targets'][0]['legendFormat'] = '{{' + by + '}}'
    g = copy.deepcopy(verdict['gridPos']); g['y'] = verdict['gridPos']['y'] + verdict['gridPos']['h']; g['x'] = i * 12; g['w'] = 12
    p['gridPos'] = g; new.append(p)
y = verdict['gridPos']['y']; last = max(i for i, p in enumerate(container) if p.get('gridPos', {}).get('y') == y)
for k, p in enumerate(new): container.insert(last + 1 + k, p)
h = new[0]['gridPos']['h']
for p in container:
    if p not in new and p.get('gridPos', {}).get('y', 0) > y: p['gridPos']['y'] += h
if suffix and not d['title'].endswith(suffix): d['title'] += suffix
d['version'] = d.get('version', 0) + 1
json.dump(d, open(dst, 'w'), indent=1); print("added:", [p['title'] for p in new], "→", dst)
