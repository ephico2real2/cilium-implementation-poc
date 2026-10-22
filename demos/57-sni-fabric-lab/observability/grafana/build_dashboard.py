#!/usr/bin/env python3
"""Generates the lab's Grafana dashboard, observability/grafana/dashboards/fabric.json.

Usage: python observability/grafana/build_dashboard.py
The generator is the source: edit it, never the JSON. It follows diagram-kit's dashboard
standard: one section per reader question, fixed Tableau 10 colours per identity, one query
per coloured line (so the Perses form keeps its colours), fixed [5m] rate windows stated in
each description, line width 1 with a 10% shade, legends below, units set.
Which metrics were chosen, and why, is in docs/metrics/dashboard-choices.md.
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "dashboards" / "fabric.json"
DS = {"type": "prometheus", "uid": "prometheus"}

BLUE, RED, YELLOW, PURPLE = "#4e79a7", "#e15759", "#edc948", "#b07aa1"
GREEN, ORANGE, TEAL = "#59a14f", "#f28e2b", "#76b7b2"
DASH = {"fill": "dash", "dash": [8, 6]}
DOT = {"fill": "dot", "dash": [2, 6]}

# The edge_sni tenants, each with its fixed colour in every panel.
TENANTS = [("web", "web", BLUE), ("orders_api", "orders-api", RED), ("tcp_svc", "tcp-svc", YELLOW),
           ("mq_qm1", "MQ listener", PURPLE), ("mq_console", "MQ console", TEAL)]

panels: list[dict] = []
_next_id = 0
_y = 0


def _id() -> int:
    global _next_id
    _next_id += 1
    return _next_id


def row(title: str) -> None:
    global _y
    panels.append({"type": "row", "title": title, "collapsed": False, "id": _id(),
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y}, "panels": []})
    _y += 1


def caption(text: str) -> None:
    """A transparent text panel under a section: what matters, for the reader who never hovers."""
    global _y
    # Titled: Perses names every panel, and an empty Grafana title converts to "empty".
    panels.append({"type": "text", "title": "In short", "id": _id(), "transparent": True,
                   "gridPos": {"h": 3, "w": 24, "x": 0, "y": _y},
                   "options": {"mode": "markdown", "content": text}})
    _y += 3


def target(ref: str, expr: str, legend: str, instant: bool = False) -> dict:
    t = {"refId": ref, "datasource": DS, "expr": expr, "legendFormat": legend}
    if instant:
        t.update(instant=True, format="table")
    else:
        t["range"] = True
    return t


def series_override(ref: str, color: str, index: int, fill: int = 10) -> dict:
    """Colour, shade and line style for one query: second line dashed, third dotted."""
    props = [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}},
             {"id": "custom.fillOpacity", "value": fill}]
    if index % 3 == 1:
        props.append({"id": "custom.lineStyle", "value": DASH})
    elif index % 3 == 2:
        props.append({"id": "custom.lineStyle", "value": DOT})
    return {"matcher": {"id": "byFrameRefID", "options": ref}, "properties": props}


def timeseries(x: int, y: int, title: str, description: str, unit: str,
               lines: list[tuple[str, str, str]], stacked: bool = False, minimum: float | None = 0,
               maximum: float | None = None, w: int = 12, h: int = 8) -> None:
    """lines: (expr, legend, colour), one query each."""
    refs = [chr(ord("A") + i) for i in range(len(lines))]
    custom: dict = {"lineWidth": 1, "fillOpacity": 30 if stacked else 10, "showPoints": "never"}
    if stacked:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    defaults: dict = {"unit": unit, "custom": custom}
    if minimum is not None:
        defaults["min"] = minimum
    if maximum is not None:
        defaults["max"] = maximum
    panels.append({
        "type": "timeseries", "title": title, "description": description, "id": _id(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [target(r, e, legend) for r, (e, legend, _) in zip(refs, lines)],
        "fieldConfig": {"defaults": defaults,
                        "overrides": [series_override(r, c, i, 30 if stacked else 10)
                                      for i, (r, (_, _, c)) in enumerate(zip(refs, lines))]},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "none"}},
    })


def stat(x: int, y: int, title: str, description: str, expr: str, unit: str = "none",
         thresholds: list[tuple[float | None, str]] | None = None, w: int = 12, h: int = 8) -> None:
    steps = [{"color": c, "value": v} for v, c in (thresholds or [(None, BLUE)])]
    panels.append({
        "type": "stat", "title": title, "description": description, "id": _id(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [target("A", expr, "")],
        "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "thresholds"},
                                     "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "area", "textMode": "value", "justifyMode": "auto"},
    })


# ---------------------------------------------------------------- 1. Is every part up?
row("Is every part of the lab up?")
y = _y
panels.append({
    "type": "table", "title": "Each component, now",
    "description": "Prometheus's own up series per scrape job, all scraped through Envoy's mesh_http listener. "
                   "Up means the last scrape of that component's metrics succeeded through Envoy; Down means it "
                   "did not, which is either the component or its Envoy route.",
    # Height 9: six components and the header; at 8 the last row was cut (measured in the capture).
    "id": _id(), "datasource": DS, "gridPos": {"h": 9, "w": 12, "x": 0, "y": y},
    "targets": [target("A", "max by (job) (up)", "", instant=True)],
    "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True},
                                                       "renameByName": {"job": "Component", "Value": "State"}}}],
    "fieldConfig": {"defaults": {}, "overrides": [{
        "matcher": {"id": "byName", "options": "State"},
        "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
                       {"id": "mappings", "value": [{"type": "value", "options": {
                           "1": {"text": "Up", "color": GREEN, "index": 0},
                           "0": {"text": "Down", "color": RED, "index": 1}}}]}]}]},
    "options": {"showHeader": True, "cellHeight": "sm"},
})
panels.append({
    "type": "status-history", "title": "Each component, over time",
    "description": "The same up series over the time range: green while the scrape through Envoy succeeds, red "
                   "while it fails. A red stripe on every component at once points at Envoy or Prometheus.",
    "id": _id(), "datasource": DS, "gridPos": {"h": 9, "w": 12, "x": 12, "y": y},
    "targets": [target("A", "max by (job) (up)", "{{job}}")],
    "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": GREEN},
                                 "mappings": [{"type": "value", "options": {
                                     "1": {"text": "Up", "color": GREEN, "index": 0},
                                     "0": {"text": "Down", "color": RED, "index": 1}}}]},
                    "overrides": []},
    "options": {"showValue": "never", "rowHeight": 0.8, "colWidth": 0.95,
                "legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single"}},
})
_y = y + 9
caption("Every component is scraped **through Envoy**, so *Up* also proves Envoy's route to it works.")

# ---------------------------------------------------------------- 2. The shared TLS port
row("Who uses the shared TLS port?")
y = _y
timeseries(0, y, "New connections per tenant (per second)",
           "Connections Envoy's edge_sni listener accepted and passed through, per tenant hostname (its filter "
           "chain), rate over 5m. Stacked: the bands add up to all accepted connections. TLS is not ended at "
           "Envoy, so this counts connections, not requests.",
           "cps", [(f'sum(rate(envoy_tcp_downstream_cx_total{{envoy_tcp_prefix="{p}"}}[5m]))', n, c)
                   for p, n, c in TENANTS], stacked=True)
timeseries(12, y, "Connections reset: unknown or missing SNI (per second)",
           "Connections whose TLS hostname matched no tenant, so Envoy reset them; rate over 5m. Normal is 0 "
           "apart from probes. A client that sends MQ's channel-based SNI (OutboundSNI=CHANNEL) lands here.",
           "cps", [('sum(rate(envoy_listener_no_filter_chain_match_total{envoy_listener_address="0.0.0.0_10443"}[5m]))',
                    "reset, no tenant matched", RED)])
_y = y + 8
caption("Each band is one tenant hostname on the **one** port; anything that matches none is reset (right).")

# ---------------------------------------------------------------- 3. Retries
row("Do calls between services fail, and do Envoy's retries save them?")
y = _y
timeseries(0, y, "Status updates: 5xx answered vs. 5xx that reached the worker (per second)",
           "The worker's PUT /orders/{id}/status, rate over 5m. Answered by orders-api counts every attempt "
           "orders-api itself answered with a 5xx (its own request counter). Reached the worker counts the 5xx "
           "Envoy passed back after its retries: Envoy's upstream_rq_xx counts only that final answer, not "
           "each attempt. The gap between the two lines is what the retries absorbed.",
           "reqps", [
               ('sum(rate(orders_api_http_requests_total{server="internal",route="/orders/{order_id}/status",'
                'status=~"5.."}[5m]))', "5xx answered by orders-api (every attempt)", RED),
               ('sum(rate(envoy_cluster_upstream_rq_xx_total{envoy_cluster_name="orders_api_internal",'
                'envoy_response_code_class="5"}[5m]))', "5xx that reached the worker (after retries)", ORANGE)])
timeseries(12, y, "Envoy's retries to orders-api (per second)",
           "Envoy's mesh_http cluster orders_api_internal, rate over 5m. Retries: extra attempts Envoy made "
           "after a failed one. Retried and succeeded: requests a retry rescued. The admin portal's chaos "
           "switch makes these move; normal is 0.",
           "reqps", [
               ('sum(rate(envoy_cluster_upstream_rq_retry_total{envoy_cluster_name="orders_api_internal"}[5m]))',
                "retries", ORANGE),
               ('sum(rate(envoy_cluster_upstream_rq_retry_success_total{envoy_cluster_name="orders_api_internal"}[5m]))',
                "retried and succeeded", GREEN)])
_y = y + 8
caption("Envoy retries only what is safe: PUTs on failure; POSTs and MQ's destructive DELETE only "
        "if the request never reached the service. The gap on the left is what retries absorbed.")

# ---------------------------------------------------------------- 4. Orders end to end
row("Are orders flowing end to end?")
y = _y
timeseries(0, y, "Orders created, replayed and processed (per second)",
           "Created: new orders (orders-api). Replayed: repeats of a POST with the same Idempotency-Key, answered "
           "from the stored order. Processed: orders the worker marked processed after taking their event off "
           "IBM MQ. Rate over 5m. Created and processed should run level.",
           "ops", [
               ("sum(rate(orders_api_orders_created_total[5m]))", "created", BLUE),
               ('sum(rate(worker_messages_total{result="processed"}[5m]))', "processed", GREEN),
               ("sum(rate(orders_api_orders_replayed_total[5m]))", "replayed (same key)", YELLOW)])
timeseries(12, y, "Events that needed another try (per second)",
           "Requeued: the worker's update still failed after Envoy's retries, so it put the event back. "
           "Dead-lettered: given up after 5 attempts, or the order was missing. Lost: even the put-back failed. "
           "Re-sent by the sweeper: orders still created 60 s after their last event. Rate over 5m; normal is 0.",
           "ops", [
               ('sum(rate(worker_messages_total{result="requeued"}[5m]))', "requeued by the worker", ORANGE),
               ('sum(rate(worker_messages_total{result="dead_lettered"}[5m]))', "dead-lettered", RED),
               ("sum(rate(orders_api_sweep_republish_total[5m]))", "re-sent by the sweeper", PURPLE)])
_y = y + 8
caption("An order is saved in Postgres, announced on IBM MQ, and marked processed by the worker: "
        "every hop through Envoy.")

# ---------------------------------------------------------------- 5. Latency
row("Is it fast?")
y = _y
timeseries(0, y, "orders-api request duration, 95th percentile (seconds)",
           "From orders-api's own request-duration buckets, 95th percentile over 5m, for the public server "
           "(browser and Swagger, through edge_sni) and the internal one (worker and Prometheus, through "
           "mesh_http). Empty while a server had no requests.",
           "s", [
               ('histogram_quantile(0.95, sum by (le) (rate(orders_api_http_request_seconds_bucket{server="public"}[5m])))',
                "public (TLS)", BLUE),
               ('histogram_quantile(0.95, sum by (le) (rate(orders_api_http_request_seconds_bucket{server="internal"}[5m])))',
                "internal (mesh)", RED)])
timeseries(12, y, "Worker status update, retries included (seconds)",
           "How long the worker's PUT /orders/{id}/status took as the worker saw it, Envoy's retries and their "
           "back-off included; 50th and 95th percentile over 5m. Retries show here as a longer tail.",
           "s", [
               ("histogram_quantile(0.5, sum by (le) (rate(worker_status_update_seconds_bucket[5m])))", "50th percentile", BLUE),
               ("histogram_quantile(0.95, sum by (le) (rate(worker_status_update_seconds_bucket[5m])))", "95th percentile", RED)])
_y = y + 8
caption("Percentiles from buckets, not averages: the slow tail is where retries show.")

# ---------------------------------------------------------------- 6. IBM MQ
row("Is IBM MQ busy and healthy?")
y = _y
timeseries(0, y, "Queue manager: messages put and got (per second)",
           "Queue manager QM1, all queues: messages put (MQPUT and MQPUT1) and destructively got, rate over "
           "5m. The container's metrics are queue-manager-wide only; per-queue counts are in the admin portal.",
           "ops", [("sum(rate(ibmmq_qmgr_mqput_mqput1_total[5m]))", "put", BLUE),
                   ("sum(rate(ibmmq_qmgr_destructive_get_total[5m]))", "got", RED)])
# A stat: the value held steady in every capture (232 µs), so "what is it now" is the question.
stat(12, y, "Queue manager: recovery log write latency, now (seconds)",
     "QM1's own measure of how long a write to its recovery log takes; the last value, with its trend. "
     "Every persistent put waits for it, so this is MQ's saturation signal. This lab runs MQ under amd64 "
     "emulation: read it as a trend, not as a production number.",
     "max(ibmmq_qmgr_log_write_latency_seconds)", unit="s",
     thresholds=[(None, GREEN), (0.01, ORANGE), (0.05, RED)])
_y = y + 8
caption("MQ's metrics are scraped through Envoy too (`/metrics/mq`); MQ itself sees only Envoy.")

# ---------------------------------------------------------------- 7. Postgres and tcp-svc
row("Are Postgres and the TCP service answering?")
y = _y
timeseries(0, y, "Postgres: transactions (per second)",
           "Database fabric, from postgres-exporter (which also reaches Postgres through Envoy's mesh_pg): "
           "commits and rollbacks, rate over 5m. Rollbacks should stay near 0.",
           "ops", [('sum(rate(pg_stat_database_xact_commit_total{datname="fabric"}[5m]))', "commits", BLUE),
                   ('sum(rate(pg_stat_database_xact_rollback_total{datname="fabric"}[5m]))', "rollbacks", RED)])
timeseries(12, y, "tcp-svc: commands (per second)",
           "Commands tcp-svc answered over its TLS line protocol, by command, rate over 5m. The Orders page's "
           "Ping button and the API's health check send PING.",
           "ops", [(f'sum(rate(tcp_svc_commands_total{{command="{cmd}"}}[5m]))', cmd.upper(), c)
                   for cmd, c in (("ping", BLUE), ("echo", RED), ("time", YELLOW), ("unknown", PURPLE))])
_y = y + 8

dashboard = {
    "title": "SNI Fabric Lab",
    "uid": "sni-fabric-lab",
    "description": "Envoy as the only path between every component: the shared SNI port, retries on the mesh, "
                   "orders end to end, IBM MQ and Postgres. Generated by observability/grafana/build_dashboard.py.",
    "tags": ["envoy", "sni", "ibm-mq", "lab"],
    "timezone": "browser",
    "schemaVersion": 41,
    "version": 1,
    "editable": False,
    "graphTooltip": 1,
    "refresh": "10s",
    "time": {"from": "now-30m", "to": "now"},
    "templating": {"list": []},
    "annotations": {"list": []},
    "links": [],
    "panels": panels,
}

OUT.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {OUT} ({len([p for p in panels if p['type'] not in ('row', 'text')])} panels, "
      f"{len([p for p in panels if p['type'] == 'row'])} sections)")
