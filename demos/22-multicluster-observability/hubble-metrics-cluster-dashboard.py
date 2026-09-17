#!/usr/bin/env python3
"""hubble-metrics-cluster-dashboard.py <chart dashboard json> > <lab dashboard json>

Cilium's chart dashboard "Hubble Metrics and Monitoring" (uid 5HftnJAWz) has no `cluster` variable: 0 of its 38 panels
filter on the label, so since demo 22's spoke every panel silently sums poc1 and poc2. The lab's other Hubble dashboards
follow the multi-cluster convention — `external_labels.cluster` on each Prometheus, a `cluster` variable from
label_values, `cluster=~"$cluster"` in every query (demo 16 Part 9 stamped the label for exactly this). This script
gives the chart's dashboard the same: a `cluster` template variable (query `label_values(hubble_flows_processed_total,
cluster)`, multi-value, "All" = `.*`) and the selector `cluster=~"$cluster"` added to every metric selector of every
query — existing `{…}` selectors are extended, bare metric names get one. Nothing else changes; Cilium's original stays
provisioned by the chart, this copy is provisioned beside it as "Hubble Metrics and Monitoring (per cluster)"."""
import json, re, sys
d = json.load(open(sys.argv[1]))
d["title"] = "Hubble Metrics and Monitoring (per cluster)"
d["uid"] = "hubble-metrics-per-cluster"; d["id"] = None
d.pop("__inputs", None); d.pop("__requires", None)
METRIC = re.compile(r'\b(hubble_[a-z0-9_]+)(\{[^}]*\})?')
def add_cluster(expr):
    def sub(m):
        name, sel = m.group(1), m.group(2)
        if sel and 'cluster=' in sel: return m.group(0)
        inner = sel[1:-1].strip() if sel else ''
        return '%s{%s%scluster=~"$cluster"}' % (name, inner, ', ' if inner else '')
    return METRIC.sub(sub, expr)
n = 0
def walk(panels):
    global n
    for p in panels:
        if p.get("panels"): walk(p["panels"])
        for t in p.get("targets", []):
            if "expr" in t: t["expr"] = add_cluster(t["expr"]); n += 1
walk(d["panels"])
d["templating"]["list"].append({
    "name": "cluster", "label": "cluster", "type": "query", "datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"},
    "definition": "label_values(hubble_flows_processed_total, cluster)",
    "query": {"query": "label_values(hubble_flows_processed_total, cluster)", "refId": "PrometheusVariableQueryEditor-VariableQuery"},
    "refresh": 2, "includeAll": True, "allValue": ".*", "multi": True, "sort": 1, "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
})
sys.stderr.write("queries given a cluster selector: %d\n" % n)
json.dump(d, sys.stdout, separators=(",", ":"))
