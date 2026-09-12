#!/usr/bin/env python3
"""tracetree.py — print one distributed trace as a tree from the OTel collector's debug-exporter output.
Usage:  kubectl -n otel logs <pod> | tracetree.py [trace-id | span-name-substring]
Default: the newest trace containing a span named 'POST /api/pay'. Reads the `debug` exporter's detailed
format (ResourceSpans / Resource attributes / Span # blocks) — the demo 10 collector emits exactly that."""
import sys, re
lines = sys.stdin.read().splitlines()
spans, res = [], {}
for l in lines:
    if l.startswith('ResourceSpans #'): res = {}
    m = re.match(r'\s+-> (k8s\.cluster\.name|service\.name|k8s\.deployment\.name): Str\((.*)\)', l)
    if m and not spans or (m and l.startswith('     -> ') and 'Span #' not in l and not re.match(r'Span #', l)):
        res[m.group(1)] = m.group(2) if m else None
    if l.startswith('Span #'): spans.append({'res': dict(res), 'attrs': {}})
    elif spans:
        s = spans[-1]
        m2 = re.match(r'\s+(Trace ID|Parent ID|ID|Name|Kind|Start time|End time)\s*: (.*)', l)
        if m2: s[m2.group(1)] = m2.group(2).strip()
        m3 = re.match(r'\s+-> ([\w.]+): \w+\((.*)\)', l)
        if m3: s['attrs'][m3.group(1)] = m3.group(2)
arg = sys.argv[1] if len(sys.argv) > 1 else 'POST /api/pay'
tid = arg if re.fullmatch(r'[0-9a-f]{32}', arg) else next((s['Trace ID'] for s in reversed(spans) if arg in s.get('Name','')), None)
if not tid: sys.exit(f"no span matching {arg!r} in {len(spans)} spans")
tr = [s for s in spans if s.get('Trace ID') == tid]
byid = {s['ID']: s for s in tr}
def dur(s):
    try:
        import datetime as d; f=lambda t: d.datetime.strptime(t[:26], '%Y-%m-%d %H:%M:%S.%f'); return '%.1f ms' % ((f(s['End time'])-f(s['Start time'])).total_seconds()*1000)
    except Exception: return ''
def show(s, depth):
    a = s['attrs']; r = s['res']
    extra = a.get('db.query.text') or a.get('server.address') or ''
    print('  ' * depth + f"{s['Name']}  [{s['Kind']}]  {r.get('k8s.cluster.name','?')}/{r.get('service.name','?')}  {dur(s)}  {extra[:60]}")
    for c in sorted((c for c in tr if c.get('Parent ID') == s['ID']), key=lambda c: c.get('Start time','')): show(c, depth + 1)
roots = [s for s in tr if not s.get('Parent ID') or s['Parent ID'] not in byid]
print(f"trace {tid}: {len(tr)} spans, clusters {sorted(set(s['res'].get('k8s.cluster.name','?') for s in tr))}")
for r in sorted(roots, key=lambda s: s.get('Start time','')): show(r, 0)
