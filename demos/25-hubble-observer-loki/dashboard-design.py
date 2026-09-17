#!/usr/bin/env python3
"""dashboard-design.py <in.json> <out.json>

Apply the designed Hubble-observer dashboard (the fork's cilium-hubble-flows.json).
Each step is a replace, so a second run on the output is a no-op.

  1. Colour defect fixed by aligning the query mode: with an instant query and
     "All values" Grafana colours the rows of one field by value, so equal counts
     get equal colours — measured 2026-09-17: 28 %/28 % both rgb(87,148,242),
     33/33/33 all rgb(115,191,105); the panels that already use a range query
     with "Calculate" colour per series.
  2. Semantic fixed colours: a verdict, a direction and a drop reason each have
     a fixed meaning; the same meaning must have the same colour on every load,
     not a palette index.
  3. Two rankings become bar gauges: Grafana's own guidance — a pie shows
     proportion of a whole and reads badly with near-equal slices (28/28/27/18
     measured); a ranking of who is being dropped is a categorical comparison,
     which a horizontal bar gauge shows with the count beside each name.
     Measured 2026-09-17: a range query is one frame per series, so sortBy
     cannot order them; instant + All values is one table frame (rows = labels)
     whose value field is named `Value #A`. Length carries magnitude — a heat
     gradient added an alarm the count does not justify.
  4. Captions under every Statistics panel: the operator asked for "a little
     legend below each" so a reader knows what a panel counts and what makes it
     empty; a Grafana `description` only shows on hover. The marker must sit on
     its own line (a blank line before the text) or CommonMark treats the
     whole line as an HTML block and the markdown stays raw. Strips under the
     two Statistics bands are h=3 (h=2 cut the text); the timeseries strip
     stays h=2.
  5. Descriptions (hover text) on every panel that has none.
"""
import json, sys, copy

CAPTION_MARK = '<!-- caption -->'

# §1: Direction was instant + All values (the colour defect); it becomes range
# + Calculate. The two rankings are instant on purpose (see to_bargauge).
RANGE_LEGEND = {
    'Flows per Direction': '{{flow_traffic_direction}}',
}

VERDICT_COLORS = [
    ('DROPPED', 'red'), ('FORWARDED', 'green'), ('AUDIT', 'yellow'),
    ('REDIRECTED', 'blue'), ('ERROR', 'purple'),
    ('TRACED', 'text'), ('TRANSLATED', 'text'), ('UNKNOWN', 'text'),
]

# Marker on its own line, then a blank line: CommonMark otherwise treats
# `<!-- caption -->text` as one HTML block and leaves * / ` visible.
CAPTIONS = {
    'Total Flows':
        '**Dropped flows** in the range — the observer streams `verdict=DROPPED` only (chart value `verdictFilter`).',
    'Flows per Verdict':
        '100 % DROPPED with the default filter; `verdictFilter: none` shows FORWARDED / AUDIT / REDIRECTED too.',
    'Flows per Direction':
        'Whose policy dropped it: **EGRESS** = at the source (its egress rules), **INGRESS** = at the destination (its ingress rules).',
    'Flows per Destination':
        'Only flows whose destination IP was resolved through Cilium\'s DNS proxy carry a name (`destination_names`, an L7 DNS rule on the source). Empty = no DNS-visibility policy on the dropped sources.',
    'Top dropped destinations — by DNS name':
        'Only flows whose destination IP was resolved through Cilium\'s DNS proxy carry a name (`destination_names`, an L7 DNS rule on the source). Empty = no DNS-visibility policy on the dropped sources.',
    'Flows per Source Namespace':
        'Who is being denied, ranked by dropped flows (top 10). Flows without a source namespace (host, world, remote-node identities) are excluded.',
    'Top dropped sources — by namespace':
        'Who is being denied, ranked by dropped flows (top 10). Flows without a source namespace (host, world, remote-node identities) are excluded.',
    'Flows per Drop Reason':
        '**POLICY_DENIED** = no rule allowed it (default deny). **POLICY_DENY** = an explicit deny rule. **STALE_OR_UNROUTABLE_IP** = the destination IP is gone (a pod that no longer exists). Others: datapath, not policy.',
    'Policy drops by denying policy':
        'Names the deny rule from `egress_denied_by` / `ingress_denied_by`; a default-deny drop names none (gotcha #82), so it counts as "default deny (no matching allow)".',
    'Flows over time, by verdict':
        'Drops per 30 s. A step up at a moment = a policy took effect or a client started failing; a flat line at zero is the goal after enforcement.',
}

DESCRIPTIONS = {
    'Total Flows':
        'Count of flow lines the observer wrote to Loki in the time range, after the dashboard\'s filters. With verdictFilter=DROPPED (default) this is the number of dropped flows.',
    'Flows per Verdict':
        'Hubble verdict of each flow (flow.verdict): FORWARDED, DROPPED, AUDIT (would have been dropped, policy audit mode), REDIRECTED (to the L7 proxy), ERROR, TRACED. The observer\'s verdictFilter decides which verdicts reach Loki at all.',
    'Flows per Direction':
        'flow.traffic_direction as Cilium saw the packet at the enforcement point: EGRESS = at the source endpoint, INGRESS = at the destination endpoint. For a drop it says whose policy decided.',
    'Top dropped sources — by namespace':
        'topk(10) of dropped flows by flow.source.namespace. Sources without a namespace (host, world, remote-node, kube-apiserver identities) are filtered out by flow_source_namespace!="".',
    'Top dropped destinations — by DNS name':
        'topk(10) of dropped flows by flow.destination_names[0] — the DNS name Cilium\'s DNS proxy recorded for the destination IP. A name is present only when the source is under an L7 DNS policy (rules.dns) so the proxy saw the lookup.',
    'Cilium Flows over Time':
        'Every dropped flow as a row: time, verdict, source and destination (pod, job or labels), namespaces, clusters, direction, destination port, drop reason, UUID. The Flow UUID column links to cf2cnp (Generate CiliumNetworkPolicy).',
    'Unique Cilium Flows':
        'The same rows deduplicated by the pattern of source, destination and port, so one recurring drop shows once.',
    'Raw flow lines':
        'The observer\'s JSON lines as written, one per dropped flow; the fields the fieldMask kept.',
}


def walk(ps):
    for p in ps:
        yield p
        if p.get('panels'):
            yield from walk(p['panels'])


def find(ps, title):
    for p in walk(ps):
        if p.get('title') == title:
            return p


def find_any(ps, *titles):
    for t in titles:
        p = find(ps, t)
        if p:
            return p


def max_id(ps):
    return max((p.get('id', 0) for p in walk(ps)), default=0)


def is_caption(p):
    # Both `<!-- caption -->text` (first brief) and `<!-- caption -->\n\ntext`.
    return p.get('type') == 'text' and str((p.get('options') or {}).get('content', '')).startswith(CAPTION_MARK)


def caption_content(text):
    return CAPTION_MARK + '\n\n' + text


def caption_h(panel):
    return 2 if panel.get('type') == 'timeseries' else 3


def as_range(p, legend):
    # Instant + All values colours *rows of one field* by the number; range + Calculate
    # gives Grafana one series per label, which is what palette-classic / byName colour.
    t = p['targets'][0]
    t['queryType'] = 'range'
    t.pop('instant', None)
    t['range'] = True
    t['legendFormat'] = legend
    ro = p.setdefault('options', {}).setdefault('reduceOptions', {})
    ro['values'] = False
    ro['calcs'] = ['lastNotNull']
    ro['fields'] = ''


def upsert_color(p, matcher_id, name, color):
    # Same meaning → same colour on every load; replace, never a second override for the name.
    ov = {'matcher': {'id': matcher_id, 'options': name},
          'properties': [{'id': 'color', 'value': {'mode': 'fixed', 'fixedColor': color}}]}
    lst = p.setdefault('fieldConfig', {}).setdefault('overrides', [])
    for i, existing in enumerate(lst):
        m = existing.get('matcher') or {}
        if m.get('id') == matcher_id and m.get('options') == name:
            lst[i] = ov
            return
    lst.append(ov)


def apply_named_colors(p, pairs):
    for name, color in pairs:
        upsert_color(p, 'byName', name, color)


def wrap_topk(expr):
    if expr.lstrip().startswith('topk('):
        return expr
    return 'topk(10, ' + expr + ')'


def to_bargauge(p, title):
    p['type'] = 'bargauge'
    p['title'] = title
    t = p['targets'][0]
    t['expr'] = wrap_topk(t['expr'])
    # Instant + All values → one table frame (rows = labels). sortBy can then
    # order `Value #A`. A range query is one frame per series and does not sort.
    t['queryType'] = 'instant'
    t.pop('range', None)
    t.pop('legendFormat', None)
    # Pie options (pieType / tooltip / sort) do not apply to a bar gauge.
    p['options'] = {
        'displayMode': 'gradient', 'orientation': 'horizontal', 'valueMode': 'text',
        'showUnfilled': True, 'sizing': 'auto', 'minVizHeight': 16, 'maxVizHeight': 32,
        'namePlacement': 'left',
        'reduceOptions': {'values': True, 'calcs': ['lastNotNull'], 'fields': ''},
        'legend': {'showLegend': False},
    }
    defaults = p.setdefault('fieldConfig', {}).setdefault('defaults', {})
    defaults['unit'] = 'short'
    defaults['min'] = 0
    defaults['color'] = {'mode': 'fixed', 'fixedColor': 'semi-dark-blue'}
    p['transformations'] = [{'id': 'sortBy', 'options': {'sort': [{'field': 'Value #A', 'desc': True}]}}]


def stats_children(panels):
    # Expanded Statistics row: its panels sit at top level until the next row.
    out, in_stats = [], False
    for p in panels:
        if p.get('type') == 'row':
            if p.get('title') == 'Statistics':
                in_stats = True
                continue
            if in_stats:
                break
        elif in_stats and not is_caption(p):
            out.append(p)
    return out


def find_caption_under(panel, panels):
    gp = panel['gridPos']
    want_y = gp['y'] + gp['h']
    for p in walk(panels):
        if not is_caption(p):
            continue
        cg = p.get('gridPos') or {}
        if cg.get('x') == gp['x'] and cg.get('w') == gp['w'] and cg.get('y') == want_y:
            return p


def shift_from(panels, y_min, dy, exclude):
    for p in walk(panels):
        if p in exclude:
            continue
        gp = p.get('gridPos')
        if gp and gp.get('y', 0) >= y_min:
            gp['y'] += dy


def add_captions(d):
    # One strip per band. Band captions are h=3 (h=2 cut the text); the
    # timeseries strip stays h=2. Existing <!-- caption --> panels are replaced
    # (old single-line or new form). Shift is the strip's actual height, or the
    # delta when a strip already exists at a different h — never a hardcoded 2.
    nid = max_id(d['panels'])
    children = stats_children(d['panels'])
    by_y = {}
    for p in children:
        by_y.setdefault(p['gridPos']['y'], []).append(p)
    for y in sorted(by_y):
        touched = []
        for p in by_y[y]:
            content = caption_content(CAPTIONS[p['title']])
            h = caption_h(p)
            existing = find_caption_under(p, d['panels'])
            if existing:
                existing['options']['content'] = content
                existing['options']['mode'] = 'markdown'
                existing['title'] = ''
                existing['description'] = ''
                existing['transparent'] = True
                old_h = existing['gridPos']['h']
                existing['gridPos']['h'] = h
                touched.append((existing, old_h))
                continue
            nid += 1
            g = copy.deepcopy(p['gridPos'])
            g['y'] = g['y'] + g['h']
            g['h'] = h
            cap = {
                'type': 'text', 'title': '', 'description': '', 'transparent': True,
                'id': nid, 'gridPos': g,
                'options': {'mode': 'markdown', 'content': content},
                'pluginVersion': p.get('pluginVersion', '12.3.2'),
            }
            d['panels'].insert(d['panels'].index(p) + 1, cap)
            touched.append((cap, 0))
        if not touched:
            continue
        old_h = touched[0][1]
        new_h = touched[0][0]['gridPos']['h']
        dy = new_h - old_h
        if dy:
            strip_y = min(c['gridPos']['y'] for c, _ in touched)
            shift_from(d['panels'], strip_y + old_h, dy, [c for c, _ in touched])


def set_if_empty(p, text):
    if p is not None and not p.get('description'):
        p['description'] = text


src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
ps = d['panels']

for title, legend in RANGE_LEGEND.items():
    p = find(ps, title)
    if p:
        as_range(p, legend)

# palette-classic stays on defaults so unnamed categories still get distinct colours.
verdict = find(ps, 'Flows per Verdict')
if verdict:
    apply_named_colors(verdict, VERDICT_COLORS)
direction = find(ps, 'Flows per Direction')
if direction:
    apply_named_colors(direction, [('INGRESS', 'blue'), ('EGRESS', 'orange')])
reason = find(ps, 'Flows per Drop Reason')
if reason:
    apply_named_colors(reason, [
        ('POLICY_DENIED', 'red'), ('POLICY_DENY', 'dark-red'),
        ('STALE_OR_UNROUTABLE_IP', 'orange'),
        ('UNSUPPORTED_L3_PROTOCOL', 'text'), ('DROP_REASON_UNKNOWN', 'text'),
    ])
    # CT_* names cannot be listed for byName; one regexp covers the family.
    upsert_color(reason, 'byRegexp', '^CT_.*', 'purple')
    upsert_color(reason, 'byRegexp', '^L7 denied.*', 'dark-purple')
policy = find(ps, 'Policy drops by denying policy')
if policy:
    apply_named_colors(policy, [
        ('default deny (no matching allow)', 'text'),
        ('explicit deny (policy name unavailable)', 'dark-red'),
    ])
over_time = find(ps, 'Flows over time, by verdict')
if over_time:
    apply_named_colors(over_time, VERDICT_COLORS)

src_ns = find_any(ps, 'Flows per Source Namespace', 'Top dropped sources — by namespace')
if src_ns:
    to_bargauge(src_ns, 'Top dropped sources — by namespace')
dst_name = find_any(ps, 'Flows per Destination', 'Top dropped destinations — by DNS name')
if dst_name:
    to_bargauge(dst_name, 'Top dropped destinations — by DNS name')

add_captions(d)

for title, text in DESCRIPTIONS.items():
    set_if_empty(find(ps, title), text)
logs = next((p for p in walk(ps) if p.get('type') == 'logs'), None)
if logs:
    logs['title'] = 'Raw flow lines'
    set_if_empty(logs, DESCRIPTIONS['Raw flow lines'])

json.dump(d, open(dst, 'w'), indent=2)
print('wrote', dst)
