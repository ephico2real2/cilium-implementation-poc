"""Places one order with its own trace id, reads its traces back, and captures them in Grafana.

Usage: python tests/trace_capture.py <out-dir>   (from the demo directory, against the running lab)
Needs Playwright with Chromium (diagram-kit's environment).

The order goes through Envoy's edge with a W3C traceparent made here, so its trace id is known
before any store is asked, as phase6 does. The trace is then read through Grafana's datasource
proxy, and must hold the spans the tracing page discusses before any picture is taken:
  - in Tempo: orders-api's POST /orders, whose parent is the span id sent in the traceparent, with
    INSERT, the send to MQ and its POST, UPDATE and SELECT under it, and, since R1.5 carries the
    trace through MQ, the worker's process span under the send, its PUT, and orders-api's
    PUT /orders/{order_id}/status with its UPDATE;
  - in VictoriaTraces: the same span ids.
Each is then opened in Explore, light and dark, and must show its span count and span names. The
four pictures replace the previous set only when all four were taken. Prints every span and writes
the same lines to output/trace-capture.txt.
"""
import base64
import json
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

DEMO = Path(__file__).resolve().parent.parent
GRAFANA = "http://grafana.fabric.localtest.me:8080"
API = "https://api.fabric.localtest.me:8443"
OUT = DEMO / "output" / "trace-capture.txt"
lines: list[str] = []


def say(line: str) -> None:
    print(line)
    lines.append(line)


def grafana(path: str, password: str) -> dict | None:
    """GET through Grafana as admin; None for a 404 (VictoriaTraces' answer for a trace it does not
    hold yet; Tempo answers 200 with an empty trace). Any other failure stops the run."""
    request = urllib.request.Request(f"{GRAFANA}{path}")
    request.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{password}".encode()).decode())
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise SystemExit(f"FAIL  GET {path}: HTTP {error.code} {error.reason}") from None
    except (urllib.error.URLError, TimeoutError) as error:
        raise SystemExit(f"FAIL  GET {path}: {error}") from None


def place_order(trace_id: str, parent: str) -> int:
    context = ssl.create_default_context(cafile=str(DEMO / "certs" / "ca" / "ca.crt"))
    request = urllib.request.Request(f"{API}/orders", method="POST",
                                     data=json.dumps({"item": "flat white", "quantity": 1}).encode())
    request.add_header("Content-Type", "application/json")
    request.add_header("Idempotency-Key", str(uuid.uuid4()))
    request.add_header("traceparent", f"00-{trace_id}-{parent}-01")
    with urllib.request.urlopen(request, timeout=15, context=context) as response:
        order = json.loads(response.read())
        say(f"order   {order['id']} placed, HTTP {response.status}, traceparent 00-{trace_id}-{parent}-01")
        return order["id"]


def tempo_spans(document: dict | None) -> list[dict]:
    """Every span of a Tempo /api/v2/traces answer, in start order, its ids in hex."""
    spans = []
    for resource in (document or {}).get("trace", {}).get("resourceSpans", []):
        service = {a["key"]: a["value"].get("stringValue") for a in resource["resource"]["attributes"]}.get("service.name")
        for scope in resource.get("scopeSpans", []):
            for span in scope.get("spans", []):
                attrs = {a["key"]: next(iter(a["value"].values()), "") for a in span.get("attributes", [])}
                spans.append({
                    "start": int(span["startTimeUnixNano"]), "service": service,
                    "kind": span["kind"].removeprefix("SPAN_KIND_"), "name": span["name"],
                    "trace": base64.b64decode(span["traceId"]).hex(), "id": base64.b64decode(span["spanId"]).hex(),
                    "parent": base64.b64decode(span.get("parentSpanId", "")).hex(),
                    "detail": attrs.get("db.statement") or attrs.get("http.url") or attrs.get("asgi.event.type") or "",
                })
    return sorted(spans, key=lambda s: s["start"])


def server_span(spans: list[dict], service: str, name: str, parent: str) -> dict | None:
    """The one server span of that service and name whose parent is the given span id."""
    found = [s for s in spans if s["service"] == service and s["kind"] == "SERVER"
             and s["name"] == name and s["parent"] == parent]
    return found[0] if len(found) == 1 else None


def has_under(spans: list[dict], root: dict, names: list[str]) -> bool:
    """Whether each of the names is a span somewhere under root, as many times as it is listed. The
    server span ends last, but its arrival alone does not prove its children's: the SDK drops a batch
    whose export failed and sends the next. So the spans this page discusses are required by name;
    library spans (the ASGI send and receive spans, the pool's checks) are not, so a library adding
    one does not fail the run."""
    children: dict[str, list[dict]] = {}
    for span in spans:
        children.setdefault(span["parent"], []).append(span)
    seen, under, todo = {root["id"]}, Counter(), [root["id"]]
    while todo:
        for child in children.get(todo.pop(), []):
            if child["id"] not in seen:
                seen.add(child["id"])
                under[child["name"]] += 1
                todo.append(child["id"])
    return all(under[name] >= count for name, count in Counter(names).items())


def whole_order(spans: list[dict], parent: str) -> bool:
    """The order's server span under the given parent, with the page's spans under it: orders-api's
    INSERT, send and its POST, SELECT, and the worker's process span with its PUT and orders-api's
    status update under that; two UPDATEs, the events_sent count and the status."""
    server = server_span(spans, "orders-api", "POST /orders", parent)
    return server is not None and has_under(spans, server, [
        "INSERT", "send DEV.QUEUE.1", "POST", "UPDATE", "SELECT", "process DEV.QUEUE.1", "PUT",
        "PUT /orders/{order_id}/status", "UPDATE"])


def wait_for(what: str, read, ready, seconds: int = 90):
    """Calls read() every 3 s until ready(result), for at most the given seconds."""
    deadline = time.monotonic() + seconds
    while True:
        result = read()
        if ready(result):
            return result
        if time.monotonic() >= deadline:
            raise SystemExit(f"FAIL  {what}: not there within {seconds} s")
        time.sleep(3)


def show(title: str, spans: list[dict]) -> None:
    kinds = {}
    for span in spans:
        kinds[span["kind"].lower()] = kinds.get(span["kind"].lower(), 0) + 1
    say(f"{title}: {len(spans)} spans, " + " ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
    start = spans[0]["start"] if spans else 0
    for s in spans:
        say(f"  {(s['start'] - start) / 1e6:7.2f} ms  {s['service']:<10} {s['kind']:<8} {s['name']:<34} {s['detail'][:70]}")


def explore(theme: str, uid: str, ds_type: str, query: dict) -> str:
    pane = {"datasource": uid, "queries": [{"refId": "A", "datasource": {"type": ds_type, "uid": uid}, **query}],
            "range": {"from": "now-30m", "to": "now"}}
    panes = urllib.parse.quote(json.dumps({"a": pane}, separators=(",", ":")))
    return f"{GRAFANA}/explore?schemaVersion=1&orgId=1&theme={theme}&panes={panes}"


def capture(page: Page, out_dir: Path, staging: Path, name: str, theme: str, url: str, texts: list[str]) -> None:
    page.goto(url, wait_until="load")
    for text in texts:
        try:
            page.get_by_text(text, exact=False).first.wait_for(timeout=30000)
        except Exception as error:
            failed = out_dir / f"FAILED-{name}.{theme}.png"
            page.screenshot(path=str(failed))
            raise SystemExit(f"FAIL  {name} ({theme}): '{text}' did not appear ({type(error).__name__}); page: {failed}") from None
    page.wait_for_timeout(1500)  # let the span bars and fonts settle after the text appears
    page.screenshot(path=str(staging / f"{name}.{theme}.png"))
    say(f"picture {name}.{theme}.png")


def main(out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    password = (DEMO / "secrets" / "grafana-admin-password").read_text().strip()
    trace_id, parent = uuid.uuid4().hex, uuid.uuid4().hex[:16]
    place_order(trace_id, parent)

    tempo = "/api/datasources/proxy/uid/tempo"
    order = wait_for("orders-api's POST /orders under this traceparent, with the API's and the worker's spans, in Tempo",
                     lambda: tempo_spans(grafana(f"{tempo}/api/v2/traces/{trace_id}", password)),
                     lambda spans: whole_order(spans, parent))
    if {s["trace"] for s in order} != {trace_id}:
        raise SystemExit(f"FAIL  the order's trace holds spans of other traces: {sorted({s['trace'] for s in order})}")
    show(f"tempo   order trace {trace_id}", order)

    vtraces = f"/api/datasources/proxy/uid/victoriatraces/api/traces/{trace_id}"
    order_ids = {s["id"] for s in order}
    wait_for("the same span ids in VictoriaTraces",
             lambda: grafana(vtraces, password),
             lambda document: bool(document) and {span["spanID"].rjust(16, "0")
                                                  for t in document["data"] for span in t["spans"]} == order_ids)
    say(f"vtraces order trace {trace_id}: the same {len(order_ids)} span ids")

    # Pictures go to a staging directory first: a run that fails half-way leaves the last good set,
    # and the record that matches it, as they were.
    with tempfile.TemporaryDirectory(dir=out_dir) as staged, sync_playwright() as p:
        staging = Path(staged)
        browser = p.chromium.launch()
        for theme in ("light", "dark"):
            page = browser.new_page(viewport={"width": 1600, "height": 1640}, color_scheme=theme)
            page.goto(f"{GRAFANA}/login?theme={theme}", wait_until="load")
            page.fill("input[name=user]", "admin")
            page.fill("input[name=password]", password)
            page.click("button[type=submit]")
            page.wait_for_url(lambda url: "/login" not in url, timeout=20000)
            capture(page, out_dir, staging, "trace-order-tempo", theme,
                    explore(theme, "tempo", "tempo", {"queryType": "traceql", "query": trace_id}),
                    [f"{len(order)} spans", "POST /orders", "send DEV.QUEUE.1", "process DEV.QUEUE.1",
                     "PUT /orders/{order_id}/status"])
            capture(page, out_dir, staging, "trace-order-victoriatraces", theme,
                    explore(theme, "victoriatraces", "jaeger", {"queryType": "", "query": trace_id}),
                    [f"{len(order)} spans", "POST /orders", "send DEV.QUEUE.1", "process DEV.QUEUE.1",
                     "PUT /orders/{order_id}/status"])
            page.close()
        browser.close()
        for picture in staging.iterdir():
            picture.replace(out_dir / picture.name)
    OUT.write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(Path(sys.argv[1])))
