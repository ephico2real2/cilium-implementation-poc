#!/usr/bin/env python3
"""build.py — emit the six tutorial dashboards under dashboards/.

The README is the lesson; these JSON files are the charts it talks about. A tiny builder keeps every panel on the
same datasource variable, the same cluster/node variables, a caption strip, and a layout that cannot overlap — so a
rerun is identical and a missing caption is a bug in this file, not a hand-edit of the JSON."""
import json, os

PLUGIN = "13.2.1"
DS = {"type": "prometheus", "uid": "${datasource}"}
CAPTION_MARK = "<!-- caption -->"

# PromQL as measured on the lab (2026-09-17). Do not "fix" precedence — these return data.
CPU_BUSY = '100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",cluster=~"$cluster"}[5m])) * 100'
MEM_USED = '(1 - node_memory_MemAvailable_bytes{cluster=~"$cluster"} / node_memory_MemTotal_bytes{cluster=~"$cluster"}) * 100'
LOAD = 'node_load1{cluster=~"$cluster"}'
CPU_MODE = 'sum by (mode) (rate(node_cpu_seconds_total{cluster=~"$cluster",instance=~"$node"}[5m]))'
NET_TOP = 'topk(5, sum by (instance, device) (rate(node_network_receive_bytes_total{cluster=~"$cluster",device!="lo"}[5m])))'
UP = 'up{job=~".*node-exporter.*",cluster=~"$cluster"}'
UNAME = 'node_uname_info{cluster=~"$cluster"}'
PODS_NS = 'count by (namespace) (kube_pod_info{cluster=~"$cluster"})'
PODS_NS_LESSON = 'count by (namespace) (kube_pod_info{cluster=~"$cluster", namespace=~"team-.*|cf2cnp-lab.*"})'
PODS_NS_TOP10 = 'topk(10, %s)' % PODS_NS
POD_PHASE = 'sum by (phase) (kube_pod_status_phase{cluster=~"$cluster"})'
DEPLOY_RATIO = 'sum(kube_deployment_status_replicas_available{cluster=~"$cluster"}) / sum(kube_deployment_spec_replicas{cluster=~"$cluster"})'
RESTARTS = 'topk(5, sum by (namespace) (kube_pod_container_status_restarts_total{cluster=~"$cluster"}))'
FLOWS_CLUSTER = 'sum by (cluster) (rate(hubble_flows_processed_total[5m]))'
FLOWS_VERDICT = 'sum by (verdict) (rate(hubble_flows_processed_total{cluster=~"$cluster"}[5m]))'
DROPS_REASON = 'sum by (reason) (rate(hubble_drop_total{cluster=~"$cluster"}[5m]))'
NET_RX = 'sum by (instance) (rate(node_network_receive_bytes_total{cluster=~"$cluster",device!="lo"}[5m]))'
NET_RX_RATE_IV = 'sum by (cluster) (rate(node_network_receive_bytes_total{cluster=~"$cluster",device!="lo"}[$__rate_interval]))'
NET_RX_1M = 'sum by (cluster) (rate(node_network_receive_bytes_total{cluster=~"$cluster",device!="lo"}[1m]))'
NODES_ONE = 'count(kube_node_info{cluster=~"$cluster"})'
PODS_FILTERED = 'count(kube_pod_info{cluster=~"$cluster", namespace=~"$namespace"})'
FLOWS_ONE = 'sum(rate(hubble_flows_processed_total{cluster=~"$cluster"}[5m]))'


def thresholds(*pairs):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in pairs]}


def by_name(name, **props):
    properties = []
    if "color" in props:
        properties.append({"id": "color", "value": {"mode": "fixed", "fixedColor": props["color"]}})
    if "unit" in props:
        properties.append({"id": "unit", "value": props["unit"]})
    if "cell" in props:
        properties.append({"id": "custom.cellOptions", "value": props["cell"]})
    if "thresholds" in props:
        properties.append({"id": "thresholds", "value": props["thresholds"]})
    return {"matcher": {"id": "byName", "options": name}, "properties": properties}


def ranking_opts():
    # Instant + table is one frame; sortBy can then order Value. A range query cannot.
    return dict(
        instant=True, range=False, format="table",
        reduceOptions={"values": True, "calcs": ["lastNotNull"], "fields": ""},
        transformations=[
            {"id": "organize", "options": {"excludeByName": {"Time": True}}},
            {"id": "sortBy", "options": {"sort": [{"field": "Value", "desc": True}]}},
        ],
    )


def flatten(panels):
    out = []
    for p in panels:
        out.append(p)
        if p.get("panels"):
            out.extend(flatten(p["panels"]))
    return out


def assert_no_overlap(panels):
    items = [(p.get("title") or p.get("type"), p["gridPos"]) for p in flatten(panels)]
    for i, (ta, a) in enumerate(items):
        for tb, b in items[i + 1:]:
            x_hit = a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"]
            y_hit = a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]
            if x_hit and y_hit:
                raise AssertionError("overlap: %r %s vs %r %s" % (ta, a, tb, b))


def panel(ptype, title, expr, x, y, w, h, **opts):
    instant = opts.pop("instant", False)
    range_q = opts.pop("range", not instant)
    fmt = opts.pop("format", None)
    legend = opts.pop("legendFormat", None)
    target = {"datasource": DS, "editorMode": "code", "expr": expr, "refId": "A"}
    target["instant"] = bool(instant)
    target["range"] = bool(range_q)
    if fmt:
        target["format"] = fmt
    if legend is not None:
        target["legendFormat"] = legend

    color = opts.pop("color", None)
    unit = opts.pop("unit", None)
    decimals = opts.pop("decimals", None)
    min_v = opts.pop("min", None)
    max_v = opts.pop("max", None)
    mappings = opts.pop("mappings", None)
    overrides = opts.pop("overrides", None)
    trans = opts.pop("transformations", None)
    desc = opts.pop("description", None)
    line_w = opts.pop("lineWidth", None)
    fill = opts.pop("fillOpacity", None)
    ro = opts.pop("reduceOptions", None)

    defaults = {}
    if color:
        defaults["color"] = color
    if unit:
        defaults["unit"] = unit
    if decimals is not None:
        defaults["decimals"] = decimals
    if min_v is not None:
        defaults["min"] = min_v
    if max_v is not None:
        defaults["max"] = max_v
    if mappings is not None:
        defaults["mappings"] = mappings
    if "thresholds" in opts:
        defaults["thresholds"] = opts.pop("thresholds")

    custom = {}
    if ptype == "timeseries":
        custom = {
            "drawStyle": "line", "lineInterpolation": "linear",
            "lineWidth": 1 if line_w is None else line_w,
            "fillOpacity": 10 if fill is None else fill,
            "gradientMode": "none", "spanNulls": False, "insertNulls": False,
            "showPoints": "never", "pointSize": 5,
            "stacking": {"mode": "none", "group": "A"},
            "axisPlacement": "auto", "axisLabel": "",
            "scaleDistribution": {"type": "linear"},
            "hideFrom": {"tooltip": False, "viz": False, "legend": False},
            "thresholdsStyle": {"mode": "off"},
        }
    elif ptype == "state-timeline":
        custom = {
            "fillOpacity": 70, "lineWidth": 0, "spanNulls": False,
            "hideFrom": {"tooltip": False, "viz": False, "legend": False},
        }
    elif ptype == "piechart":
        custom = {"hideFrom": {"legend": False, "tooltip": False, "viz": False}}
    elif ptype == "table":
        custom = {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False, "filterable": True}
    if custom:
        defaults["custom"] = custom
    if "color" not in defaults:
        if ptype in ("timeseries", "piechart"):
            defaults["color"] = {"mode": "palette-classic"}
        elif ptype == "state-timeline":
            defaults["color"] = {"mode": "thresholds"}

    options = {}
    if ro is None:
        ro = {"values": False, "calcs": ["lastNotNull"], "fields": ""}
    if ptype in ("stat", "gauge", "bargauge", "piechart"):
        options["reduceOptions"] = ro
    if ptype == "stat":
        options["colorMode"] = opts.pop("colorMode", "value")
        options["graphMode"] = opts.pop("graphMode", "none")
        options["textMode"] = opts.pop("textMode", "auto")
        options["justifyMode"] = "auto"
        options["orientation"] = "auto"
    elif ptype == "gauge":
        options["showThresholdMarkers"] = opts.pop("showThresholdMarkers", True)
        options["showThresholdLabels"] = False
        options["orientation"] = "auto"
        options["sizing"] = "auto"
    elif ptype == "timeseries":
        options["legend"] = opts.pop("legend", {"calcs": [], "displayMode": "list", "placement": "bottom", "showLegend": True})
        options["tooltip"] = {"mode": "single", "sort": "none"}
    elif ptype == "piechart":
        options["pieType"] = opts.pop("pieType", "pie")
        options["legend"] = opts.pop("legend", {"displayMode": "list", "placement": "bottom", "showLegend": True})
        options["tooltip"] = {"mode": "single", "sort": "none"}
        options["displayLabels"] = []
    elif ptype == "bargauge":
        options["orientation"] = opts.pop("orientation", "horizontal")
        options["displayMode"] = opts.pop("displayMode", "gradient")
        options["valueMode"] = opts.pop("valueMode", "text")
        options["namePlacement"] = opts.pop("namePlacement", "left")
        options["showUnfilled"] = opts.pop("showUnfilled", True)
        options["sizing"] = "auto"
        options["minVizHeight"] = 16
        options["maxVizHeight"] = 32
        options["legend"] = {"showLegend": False, "displayMode": "list", "placement": "bottom"}
    elif ptype == "state-timeline":
        options["showValue"] = opts.pop("showValue", "never")
        options["rowHeight"] = opts.pop("rowHeight", 0.8)
        options["mergeValues"] = True
        options["alignValue"] = "left"
        options["legend"] = opts.pop("legend", {"displayMode": "list", "placement": "bottom", "showLegend": True})
        options["tooltip"] = {"mode": "single"}
    elif ptype == "table":
        options["showHeader"] = True
        options["cellHeight"] = "sm"
        options["footer"] = {"show": False, "reducer": ["sum"], "countRows": False, "fields": ""}

    if opts:
        raise TypeError("unknown panel opts: %s" % sorted(opts))

    p = {
        "type": ptype, "title": title, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": options, "targets": [target], "pluginVersion": PLUGIN,
    }
    if desc:
        p["description"] = desc
    if trans:
        p["transformations"] = trans
    return p


def caption_h(w):
    return 2 if w >= 24 else 3


def caption(text, x, y, w, h=None):
    # Marker on its own line, then a blank line: CommonMark otherwise treats the
    # comment+text as one HTML block and leaves * / ` visible.
    # Narrow strips wrap past two rows; a full-width strip fits in two.
    if h is None:
        h = caption_h(w)
    return {
        "type": "text", "title": "", "description": "", "transparent": True,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"mode": "markdown", "content": CAPTION_MARK + "\n\n" + text},
        "pluginVersion": PLUGIN,
    }


def text_panel(title, content, x, y, w, h):
    return {
        "type": "text", "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"mode": "markdown", "content": content},
        "pluginVersion": PLUGIN,
    }


def row(title, x, y, repeat=None):
    p = {
        "type": "row", "title": title, "collapsed": False,
        "gridPos": {"x": x, "y": y, "w": 24, "h": 1}, "panels": [],
    }
    if repeat:
        p["repeat"] = repeat
    return p


def _var_query(name, query, multi, include_all, refresh, current):
    v = {
        "name": name, "label": name, "type": "query",
        "datasource": DS, "definition": query,
        "query": {"query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
        "refresh": refresh, "sort": 1, "multi": multi, "includeAll": include_all,
        "current": current,
    }
    if include_all:
        v["allValue"] = ".*"
    return v


def dashboard(uid, title, panels, description, extra_vars=None, links=None):
    vars_ = [
        {
            "name": "datasource", "label": "datasource", "type": "datasource",
            "query": "prometheus", "refresh": 1, "hide": 0,
            "includeAll": False, "multi": False, "current": {"text": "", "value": ""},
        },
        _var_query(
            "cluster", "label_values(kube_node_info, cluster)",
            multi=True, include_all=True, refresh=2,
            current={"selected": True, "text": ["All"], "value": ["$__all"]},
        ),
        _var_query(
            "node", 'label_values(node_uname_info{cluster=~"$cluster"}, instance)',
            multi=False, include_all=False, refresh=1,
            current={"text": "", "value": ""},
        ),
    ]
    if extra_vars:
        vars_.extend(extra_vars)
    assert_no_overlap(panels)
    n = 1
    for p in flatten(panels):
        p["id"] = n
        n += 1
    return {
        "uid": uid, "title": title, "description": description,
        "tags": ["tutorial"], "schemaVersion": 41, "version": 1,
        "editable": True, "graphTooltip": 0, "fiscalYearStartMonth": 0,
        "refresh": "30s", "time": {"from": "now-1h", "to": "now"},
        "timezone": "browser", "templating": {"list": vars_},
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts", "type": "dashboard",
        }]},
        "links": links or [], "panels": panels,
    }


def layout(rows):
    """Place rows of cells. A cell is (panel, caption_text) or a lone panel.
    x/y are recomputed from each panel's w/h; caption height follows width."""
    out = []
    y = 0
    for row in rows:
        x = 0
        row_bottom = y
        for item in row:
            if isinstance(item, tuple):
                p, cap_text = item
            else:
                p, cap_text = item, None
            w = p["gridPos"]["w"]
            h = p["gridPos"]["h"]
            p["gridPos"]["x"] = x
            p["gridPos"]["y"] = y
            out.append(p)
            bottom = y + h
            if cap_text is not None:
                ch = caption_h(w)
                out.append(caption(cap_text, x, y + h, w, ch))
                bottom += ch
            row_bottom = max(row_bottom, bottom)
            x += w
        y = row_bottom
    return out


def tut1():
    how = text_panel(
        "How to read this page",
        "\n".join([
            "- a number now → stat",
            "- against a limit → gauge",
            "- over time → time series",
            "- share of a whole → pie (≤ 6 slices)",
            "- ranking → bar gauge",
            "- state over time → state timeline",
            "- every row → table",
        ]),
        8, 0, 8, 7,
    )
    panels = layout([
        [
            (panel(
                "stat", "A number now — CPU busy %", CPU_BUSY, 0, 0, 8, 7,
                legendFormat="{{instance}}",
                unit="percent", decimals=1, graphMode="area", colorMode="value",
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                thresholds=thresholds(("green", None), ("orange", 70), ("red", 90)),
                description="CPU busy now, per node — one number and a sparkline, coloured by threshold.",
            ), "**Stat**: one number per node, now, with a sparkline for the trend. Colour from thresholds — 70 % orange, 90 % red — so the colour answers \"is this fine?\"."),
            (panel(
                "gauge", "A number against a limit — memory used %", MEM_USED, 8, 0, 8, 7,
                legendFormat="{{instance}}",
                unit="percent", min=0, max=100, showThresholdMarkers=True,
                thresholds=thresholds(("green", None), ("orange", 80), ("red", 90)),
                description="Memory used against the only real ceiling that matters: 100 % of RAM.",
            ), "**Gauge**: only when there is a real ceiling (100 % of RAM). The needle's position IS the message; without a limit a gauge is decoration."),
            (panel(
                "timeseries", "A number over time — load average (1 m)", LOAD, 16, 0, 8, 7,
                legendFormat="{{instance}}", lineWidth=1, fillOpacity=10,
                legend={"calcs": [], "displayMode": "list", "placement": "bottom", "showLegend": True},
                description="Load average over the window, one line per node, so you can see when it moved.",
            ), "**Time series**: when the question is \"what happened, and when\". One line per node; the legend names them."),
        ],
        [
            (panel(
                "piechart", "A share of a whole — CPU time by mode on $node", CPU_MODE, 0, 0, 8, 7,
                legendFormat="{{mode}}", pieType="donut",
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                legend={"displayMode": "table", "placement": "right", "showLegend": True, "values": ["percent"]},
                overrides=[
                    by_name("idle", color="text"), by_name("user", color="blue"),
                    by_name("system", color="orange"), by_name("iowait", color="red"),
                    by_name("steal", color="purple"),
                ],
                description="CPU time on one node split by mode — the slices are the whole of that CPU.",
            ), "**Pie**: the slices add up to 100 % of one CPU's time, and there are five or six of them — the one case a pie is right. Fixed colours: idle grey, user blue, system orange, iowait red. idle is grey on purpose: it is the part of the whole that carries no information."),
            (panel(
                "bargauge", "A ranking — network receive by interface (top 5)", NET_TOP, 8, 0, 8, 7,
                unit="Bps", legendFormat="{{instance}} {{device}}",
                color={"mode": "fixed", "fixedColor": "semi-dark-blue"},
                orientation="horizontal", displayMode="gradient", valueMode="text",
                namePlacement="left", showUnfilled=True,
                description="Top 5 receive rates by interface — a ranking, so bars, sorted.",
                **ranking_opts(),
            ), "**Bar gauge**: a ranking is a comparison between categories — bars sorted by value, the number beside each name. One colour: the length already carries the size."),
            (panel(
                "state-timeline", "A state over time — node-exporter up", UP, 16, 0, 8, 7,
                legendFormat="{{instance}}", showValue="auto", rowHeight=0.8,
                # From-thresholds makes the legend "< 1" / "1+". Single-color lets
                # the mappings own both the colour and the UP/DOWN text (Grafana 13.2.1).
                color={"mode": "fixed"},
                thresholds=thresholds(("red", None), ("green", 1)),
                mappings=[{"type": "value", "options": {
                    "0": {"text": "DOWN", "color": "red", "index": 0},
                    "1": {"text": "UP", "color": "green", "index": 1},
                }}],
                legend={"displayMode": "list", "placement": "bottom", "showLegend": True},
                description="node-exporter up or down as a band — how long each state lasted.",
            ), "**State timeline**: a discrete state per moment — up/down, phase, verdict. The colour band shows how long each state lasted."),
        ],
        [
            (panel(
                "table", "Rows — node facts", UNAME, 0, 0, 8, 7,
                instant=True, range=False, format="table",
                transformations=[{"id": "organize", "options": {"excludeByName": {
                    "Time": True, "Value": True, "__name__": True, "job": True,
                    "container": True, "endpoint": True, "service": True,
                    "pod": True, "namespace": True, "domainname": True,
                }}}],
                description="One row of uname facts per node; hide the columns that carry nothing.",
            ), "**Table**: when the reader needs every row, not a shape. Hide the columns that carry nothing."),
            how,
        ],
    ])
    return dashboard(
        "tut-1-question", "Grafana 1 · The question decides the chart", panels,
        "Seven questions, seven visualizations — the chart is chosen by what you want to know, not by what looks busy.",
    )


def tut2():
    pods = PODS_NS_LESSON
    panels = layout([
        [
            (panel(
                "stat", "Range + last value", pods, 0, 0, 12, 7,
                legendFormat="{{namespace}}",
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                description="The last sample of pod count per namespace in the window.",
            ),
             "A range query returns a series per namespace; \"Calculate\" reduces each to ONE number — last value here, the mean beside it. Same data, different numbers; the reducer is part of the question."),
            (panel(
                "stat", "Range + mean over the window", pods, 12, 0, 12, 7,
                legendFormat="{{namespace}}",
                reduceOptions={"values": False, "calcs": ["mean"], "fields": ""},
                description="The mean of that same series over the window — a different number from the same data.",
            ),
             "Mean over the window hides a change that happened five minutes ago; last value hides that it was different an hour ago. Say which one you show."),
        ],
        [
            (panel(
                "piechart", "Instant + All values", pods, 0, 0, 12, 7,
                instant=True, range=False, format="table",
                reduceOptions={"values": True, "calcs": ["lastNotNull"], "fields": ""},
                description="Instant query as one table; Grafana colours rows of one field by the number.",
            ),
             "An instant query returns one table (namespace, count). \"All values\" shows each row — and Grafana colours the rows of one field by VALUE: team-a and team-b both have 2 pods and share a colour (measured on the observer dashboard, 2026-09-17, then here)."),
            (panel(
                "piechart", "Range + Calculate", pods, 12, 0, 12, 7,
                legendFormat="{{namespace}}",
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                description="Range query: one series per namespace, one colour per name.",
            ),
             "The range shape: one series per namespace, one colour per series. Same numbers as the pie on the left; team-a and team-b now differ. Prefer this shape for pies and legends."),
        ],
        [
            (panel(
                "timeseries", "rate() over $__rate_interval", NET_RX_RATE_IV, 0, 0, 12, 7,
                unit="Bps",
                description="rate() over $__rate_interval follows the panel resolution, so zooming stays continuous.",
            ),
             "$__rate_interval follows the panel's resolution (≥ 4 × scrape interval), so zooming never produces gaps. A fixed [1m] on a 30 s scrape breaks when you zoom out."),
            (panel(
                "timeseries", "rate() over a fixed [1m]", NET_RX_1M, 12, 0, 12, 7,
                unit="Bps",
                description="rate() over a fixed [1m] — the same metric, a window that does not follow the zoom.",
            ),
             "Same metric, fixed window. Zoom to 7 days and compare: this one thins out, the other stays continuous."),
        ],
    ])
    return dashboard(
        "tut-2-time", "Grafana 2 · Instant, range, reduce", panels,
        "The same PromQL, four reductions — last vs mean, instant table vs range series, $__rate_interval vs a fixed window.",
    )


def tut3():
    ts_legend = {"calcs": [], "displayMode": "list", "placement": "bottom", "showLegend": True}
    panels = layout([
        [
            (panel(
                "bargauge", "Pods per namespace (top 10)", PODS_NS_TOP10, 0, 0, 8, 8,
                color={"mode": "fixed", "fixedColor": "semi-dark-blue"},
                description="Pod count per namespace as a ranking: one colour, the length is the count.",
                **ranking_opts(),
            ), "One colour. The bar's length is the count; a colour per namespace would mean nothing and change every time a namespace appears."),
            (panel(
                "stat", "Pod phases", POD_PHASE, 8, 0, 8, 8,
                legendFormat="{{phase}}", colorMode="background", textMode="value_and_name",
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                overrides=[
                    by_name("Running", color="green"), by_name("Pending", color="yellow"),
                    by_name("Failed", color="red"), by_name("Succeeded", color="text"),
                    by_name("Unknown", color="purple"),
                ],
                description="Pod phase counts with a fixed colour per meaning, set by a byName override.",
            ), "Fixed colour per MEANING: Running is always green, Failed always red — on every dashboard, every load. Set with a byName override, never by palette position."),
            (panel(
                "gauge", "Deployments: available / desired", DEPLOY_RATIO, 16, 0, 8, 8,
                unit="percentunit", min=0, max=1,
                thresholds=thresholds(("red", None), ("orange", 0.9), ("green", 1)),
                description="Available over desired deployments — a quantity on a 0–1 scale, coloured by threshold.",
            ), "Thresholds colour a QUANTITY: below 90 % orange, below that red, 100 % green. Thresholds are for numbers on a scale; fixed colours are for categories."),
        ],
        [
            (panel(
                "piechart", "Palette by index", PODS_NS_LESSON, 0, 0, 8, 8,
                legendFormat="{{namespace}}", color={"mode": "palette-classic"},
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                description="Classic palette by series order: add a namespace and every other slice changes colour.",
            ), "The classic palette assigns colours by series ORDER: five namespaces, five colours — and a new namespace that sorts first shifts every other slice. Fine for a look, wrong for a dashboard people return to."),
            (panel(
                "piechart", "Palette by name", PODS_NS_LESSON, 8, 0, 8, 8,
                legendFormat="{{namespace}}", color={"mode": "palette-classic-by-name"},
                reduceOptions={"values": False, "calcs": ["lastNotNull"], "fields": ""},
                description="Classic palette by name: a pie, stat or bar gauge gives every series one colour (grafana/grafana#73275).",
            ), "By-name should hash the name to a stable colour. Measured on Grafana 13.2.1: in a pie, a stat or a bar gauge every series gets ONE colour (grafana/grafana#73275). Here, fix the colour per name with an override."),
            (panel(
                "table", "Restarts by namespace", RESTARTS, 16, 0, 8, 8,
                instant=True, range=False, format="table",
                transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}}}],
                overrides=[by_name("Value", unit="short", cell={"type": "color-background"},
                                   thresholds=thresholds(("green", None), ("orange", 5), ("red", 20)))],
                description="Restart totals as a heat-map column — scan for red, the number is still there.",
            ), "Cell colour from thresholds turns a table into a heat map for one column. The reader scans for red; the number is still there."),
        ],
        [
            (panel(
                "timeseries", "Time series · palette by index", PODS_NS_LESSON, 0, 0, 12, 7,
                legendFormat="{{namespace}}", color={"mode": "palette-classic"},
                legend=ts_legend,
                description="Same filtered pod-count query as the pies, drawn as lines coloured by series order.",
            ), "On a time series, by-index gives every line its own colour — until a namespace is added and the lines swap colours."),
            (panel(
                "timeseries", "Time series · palette by name", PODS_NS_LESSON, 12, 0, 12, 7,
                legendFormat="{{namespace}}", color={"mode": "palette-classic-by-name"},
                legend=ts_legend,
                description="Same query, coloured by series name — the one visualization where by-name is stable.",
            ), "On a time series, by-name WORKS: a namespace keeps its colour as others come and go (measured: 17 distinct colours for 25 names — the palette has ~20, so unrelated names can collide). This is the one place to use it."),
        ],
    ])
    return dashboard(
        "tut-3-colour", "Grafana 3 · Colour that means something", panels,
        "Colour is a signal: one colour for a ranking, a fixed colour per meaning, thresholds for a quantity, and why a palette-by-index lies.",
    )


def tut4():
    panels = layout([
        [
            (panel(
                "timeseries", "Raw", NET_RX, 0, 0, 8, 8,
                legendFormat="",
            ), "What Grafana shows when you do nothing: a number with no unit, a legend of raw labels, no explanation. The reader must guess."),
            (panel(
                "timeseries", "Unit and legend", NET_RX, 8, 0, 8, 8,
                unit="Bps", legendFormat="{{instance}}",
                legend={"calcs": ["mean", "max"], "displayMode": "table", "placement": "right", "showLegend": True},
                description="Bytes/s and a named legend — the two things a reader needs to compare nodes.",
            ), "Bytes per second, one name per node, mean and max in the legend. Now a reader can compare nodes without reading the query."),
            (panel(
                "timeseries", "Network receive per node (bytes/s)", NET_RX, 16, 0, 8, 8,
                unit="Bps", legendFormat="{{instance}}",
                legend={"calcs": ["mean", "max"], "displayMode": "table", "placement": "right", "showLegend": True},
                description="node_exporter receive bytes, rate over 5 m, per node — what this series is and where it comes from.",
            ), "A title that says what and in which unit; a hover description that says where the data comes from (node_exporter, rate over 5 m); this caption for what \"normal\" looks like. Meaning is added in words, not colours."),
        ],
        [text_panel("The checklist", "\n".join([
            "- title says what and unit",
            "- unit set",
            "- legend names the series",
            "- description says the source and the window",
            "- caption says what normal looks like and what empty means",
            "- colours mean one thing",
        ]), 0, 0, 24, 4)],
    ])
    return dashboard(
        "tut-4-meaning", "Grafana 4 · Units, legends, captions", panels,
        "A number without a unit is a guess. Title, unit, legend, description and caption each carry one kind of meaning.",
    )


def tut5():
    panels = layout([
        [caption(
            "Variables make one dashboard serve every cluster and namespace; a repeated row stamps the same panels per cluster; links hold the set together. Grow by adding variables, not by copying dashboards.",
            0, 0, 24,
        )],
        [row("Cluster: $cluster", 0, 0, repeat="cluster")],
        [
            (panel(
                "stat", "Nodes", NODES_ONE, 0, 0, 8, 6,
                color={"mode": "fixed", "fixedColor": "green"},
                description="How many nodes this cluster reports.",
            ), "A number now — how many nodes this cluster reports."),
            (panel(
                "stat", "Pods", PODS_FILTERED, 8, 0, 8, 6,
                color={"mode": "fixed", "fixedColor": "green"},
                description="How many pods in the selected namespaces of this cluster.",
            ), "A number now — pods in the selected namespaces of this cluster."),
            (panel(
                "timeseries", "Flows/s", FLOWS_ONE, 16, 0, 8, 6,
                unit="suffix: flows/s", legendFormat="flows",
                description="Hubble flows per second for this cluster.",
            ), "Over time — Hubble's pulse for this cluster."),
        ],
    ])
    extra = [_var_query(
        "namespace", 'label_values(kube_pod_info{cluster=~"$cluster"}, namespace)',
        multi=True, include_all=True, refresh=2,
        current={"selected": True, "text": ["All"], "value": ["$__all"]},
    )]
    links = [
        {
            "asDropdown": True, "icon": "external link", "includeVars": False,
            "keepTime": True, "tags": ["tutorial"], "targetBlank": False,
            "title": "Tutorial", "tooltip": "", "type": "dashboards",
        },
        {
            "asDropdown": False, "icon": "external link", "includeVars": False,
            "keepTime": True, "tags": [], "targetBlank": False,
            "title": "Hubble Observer", "type": "link",
            "url": "/d/hubble-observer-23862",
        },
    ]
    return dashboard(
        "tut-5-grow", "Grafana 5 · Grow it: variables, repeats, links", panels,
        "One dashboard, every cluster: variables, a repeated row, and links that hold the set together.",
        extra_vars=extra, links=links,
    )


def tut6():
    cells = [
        (panel(
            "stat", "Flows/s per cluster", FLOWS_CLUSTER, 0, 0, 8, 7,
            legendFormat="{{cluster}}", unit="suffix: flows/s", graphMode="area",
            color={"mode": "fixed", "fixedColor": "blue"},
            description="Hubble flows per second, one number per cluster — the pulse.",
        ), "A number now, per cluster — the pulse. Stat with sparkline."),
        (panel(
            "timeseries", "Flows/s by verdict", FLOWS_VERDICT, 8, 0, 8, 7,
            legendFormat="{{verdict}}", unit="suffix: flows/s",
            overrides=[
                by_name("FORWARDED", color="green"), by_name("DROPPED", color="red"),
                by_name("REDIRECTED", color="blue"), by_name("AUDIT", color="yellow"),
                by_name("ERROR", color="purple"),
            ],
            description="Flow rate by verdict over time; DROPPED is red on every Cilium dashboard in this lab.",
        ), "Over time, by verdict, fixed colours: DROPPED is red on every Cilium dashboard in this lab. Same meaning, same colour."),
        (panel(
            "bargauge", "Drops/s by reason", DROPS_REASON, 16, 0, 8, 7,
            unit="suffix: drops/s", decimals=2, color={"mode": "fixed", "fixedColor": "semi-dark-red"},
            description="Drop rate by reason, ranked — POLICY_DENIED first is policy doing its job.",
            namePlacement="top",  # reason names are long (STALE_OR_UNROUTABLE_IP); beside the bar they are cut
            **ranking_opts(),
        ), "A ranking of why packets are dropped. Bars, sorted, one colour — the length is the rate. POLICY_DENIED first means policy is doing its job; anything else first means something is broken."),
    ]
    panels = layout([
        cells,
        [text_panel(
            "From here",
            "\n".join([
                "The same grammar applied to Loki flow logs lives on the observer dashboard: /d/hubble-observer-23862.",
                "",
                "The panel-by-panel notes for that dashboard are docs/OBSERVER-DASHBOARD-PANELS.md in this repository.",
            ]),
            0, 0, 24, 4,
        )],
    ])
    return dashboard(
        "tut-6-cilium", "Grafana 6 · Now Cilium", panels,
        "The same grammar on Hubble metrics — pulse, verdict over time, drops ranked by reason.",
    )


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "dashboards")
    os.makedirs(out, exist_ok=True)
    for d in (tut1(), tut2(), tut3(), tut4(), tut5(), tut6()):
        path = os.path.join(out, d["uid"] + ".json")
        with open(path, "w") as f:
            json.dump(d, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("wrote", path, "panels", len(d["panels"]))


if __name__ == "__main__":
    main()
