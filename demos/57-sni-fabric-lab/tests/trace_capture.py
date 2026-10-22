"""Places one order with its own trace id, reads its traces back, and captures them in Grafana.

Usage: python tests/trace_capture.py <out-dir>   (from the demo directory, against the running lab)
Needs Playwright with Chromium (diagram-kit's environment).

The order goes through Envoy's edge with a W3C traceparent made here, so its trace id is known
before any store is asked, as phase6 does. Three traces are then read through Grafana's datasource
proxy and must have the expected spans before any picture is taken:
  - the order's trace in Tempo: orders-api's POST /orders and the spans under it;
  - the same trace in VictoriaTraces, with as many spans;
  - the worker's trace for that order: its PUT /orders/<id>/status and orders-api's spans under it
    (a trace of its own until R1.5 carries the trace through MQ).
Each is then opened in Explore, light and dark, and must show its expected span names. Prints
every span and writes the same lines to output/trace-capture.txt.
"""
import base64
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
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
    """GET through Grafana as admin; None for a 404 (a trace not there yet)."""
    request = urllib.request.Request(f"{GRAFANA}{path}")
    request.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{password}".encode()).decode())
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


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


def tempo_spans(document: dict | None) -> list[tuple]:
    """(start ns, service, kind, name, detail) for every span of a Tempo /api/v2/traces answer."""
    spans = []
    for resource in (document or {}).get("trace", {}).get("resourceSpans", []):
        service = {a["key"]: a["value"].get("stringValue") for a in resource["resource"]["attributes"]}.get("service.name")
        for scope in resource.get("scopeSpans", []):
            for span in scope.get("spans", []):
                attrs = {a["key"]: next(iter(a["value"].values()), "") for a in span.get("attributes", [])}
                detail = attrs.get("db.statement") or attrs.get("http.url") or attrs.get("asgi.event.type") or ""
                spans.append((int(span["startTimeUnixNano"]), service, span["kind"].removeprefix("SPAN_KIND_"),
                               span["name"], detail))
    return sorted(spans)


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


def show(title: str, spans: list[tuple]) -> None:
    kinds = {}
    for _, _, kind, _, _ in spans:
        kinds[kind.lower()] = kinds.get(kind.lower(), 0) + 1
    say(f"{title}: {len(spans)} spans, " + " ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
    start = spans[0][0] if spans else 0
    for at, service, kind, name, detail in spans:
        say(f"  {(at - start) / 1e6:7.2f} ms  {service:<10} {kind:<8} {name:<34} {detail[:70]}")


def explore(theme: str, uid: str, ds_type: str, query: dict) -> str:
    pane = {"datasource": uid, "queries": [{"refId": "A", "datasource": {"type": ds_type, "uid": uid}, **query}],
            "range": {"from": "now-30m", "to": "now"}}
    panes = urllib.parse.quote(json.dumps({"a": pane}, separators=(",", ":")))
    return f"{GRAFANA}/explore?schemaVersion=1&orgId=1&theme={theme}&panes={panes}"


def capture(page: Page, out_dir: Path, name: str, theme: str, url: str, texts: list[str]) -> None:
    page.goto(url, wait_until="load")
    for text in texts:
        try:
            page.get_by_text(text, exact=False).first.wait_for(timeout=30000)
        except Exception as error:
            failed = out_dir / f"FAILED-{name}.{theme}.png"
            page.screenshot(path=str(failed))
            raise SystemExit(f"FAIL  {name} ({theme}): '{text}' did not appear ({type(error).__name__}); page: {failed}") from None
    page.wait_for_timeout(1500)  # let the span bars and fonts settle after the text appears
    page.screenshot(path=str(out_dir / f"{name}.{theme}.png"))
    say(f"picture {name}.{theme}.png")


def main(out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    password = (DEMO / "secrets" / "grafana-admin-password").read_text().strip()
    trace_id, parent = uuid.uuid4().hex, uuid.uuid4().hex[:16]
    order_id = place_order(trace_id, parent)

    tempo = "/api/datasources/proxy/uid/tempo"
    order = wait_for("the order's trace in Tempo",
                     lambda: tempo_spans(grafana(f"{tempo}/api/v2/traces/{trace_id}", password)),
                     lambda spans: any(s[2] == "SERVER" and s[3] == "POST /orders" for s in spans)
                     and any(s[3] == "SELECT" for s in spans))
    show(f"tempo   order trace {trace_id}", order)

    vtraces = f"/api/datasources/proxy/uid/victoriatraces/api/traces/{trace_id}"
    copied = wait_for("the same trace in VictoriaTraces",
                      lambda: grafana(vtraces, password),
                      lambda document: bool(document) and sum(len(t["spans"]) for t in document["data"]) == len(order))
    say(f"vtraces order trace {trace_id}: {sum(len(t['spans']) for t in copied['data'])} spans")

    # The worker reports the order processed with PUT /orders/<id>/status; that call's trace.
    query = f'{{resource.service.name="worker" && span.http.url=~".*/orders/{order_id}/status"}}'
    found = wait_for("the worker's trace for the order",
                     lambda: grafana(f"{tempo}/api/search?" + urllib.parse.urlencode(
                         {"q": query, "start": int(time.time()) - 900, "end": int(time.time()) + 60}), password),
                     lambda document: bool((document or {}).get("traces")))
    worker_id = found["traces"][0]["traceID"].rjust(32, "0")
    worker = tempo_spans(grafana(f"{tempo}/api/v2/traces/{worker_id}", password))
    show(f"tempo   worker trace {worker_id}", worker)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ("light", "dark"):
            page = browser.new_page(viewport={"width": 1600, "height": 1250}, color_scheme=theme)
            page.goto(f"{GRAFANA}/login?theme={theme}", wait_until="load")
            page.fill("input[name=user]", "admin")
            page.fill("input[name=password]", password)
            page.click("button[type=submit]")
            page.wait_for_url(lambda url: "/login" not in url, timeout=20000)
            capture(page, out_dir, "trace-order-tempo", theme,
                    explore(theme, "tempo", "tempo", {"queryType": "traceql", "query": trace_id}),
                    ["POST /orders", "INSERT", "UPDATE", "SELECT"])
            capture(page, out_dir, "trace-order-victoriatraces", theme,
                    explore(theme, "victoriatraces", "jaeger", {"queryType": "", "query": trace_id}),
                    ["POST /orders", "INSERT", "UPDATE", "SELECT"])
            capture(page, out_dir, "trace-worker-tempo", theme,
                    explore(theme, "tempo", "tempo", {"queryType": "traceql", "query": worker_id}),
                    ["PUT /orders/{order_id}/status", "UPDATE"])
            page.close()
        browser.close()
    OUT.write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(Path(sys.argv[1])))
