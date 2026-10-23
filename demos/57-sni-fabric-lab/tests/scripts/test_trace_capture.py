"""Checks tests/trace_capture.py with fake Grafana answers and a fake browser: nothing of the lab runs.

Usage: python3 tests/scripts/test_trace_capture.py tests/trace_capture.py
A picture is taken only of a trace that holds the spans the tracing page discusses, under the right
parent; a run that fails half-way keeps the last pictures and record; an HTTP error is a FAIL line.
"""
import base64
import importlib.util
import io
import sys
import tempfile
import types
import urllib.error
from pathlib import Path

TRACE, PARENT = "a" * 32, "b" * 16


def load(path: str, demo: Path):
    """The script under test, with Playwright stubbed, sleeps skipped and its demo directory moved."""
    playwright = types.ModuleType("playwright.sync_api")
    playwright.Page, playwright.sync_playwright = object, None
    sys.modules["playwright"] = types.ModuleType("playwright")
    sys.modules["playwright.sync_api"] = playwright
    spec = importlib.util.spec_from_file_location("trace_capture", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.time.sleep = lambda seconds: None
    module.DEMO, module.OUT = demo, demo / "record.txt"
    return module


def b64(hex_id: str) -> str:
    return base64.b64encode(bytes.fromhex(hex_id)).decode()


def span(kind: str, name: str, span_id: str, parent: str = "", trace: str = TRACE, url: str = "") -> dict:
    out = {"startTimeUnixNano": "1", "kind": "SPAN_KIND_" + kind, "name": name, "traceId": b64(trace),
           "spanId": b64(span_id), "attributes": [{"key": "http.url", "value": {"stringValue": url}}] if url else []}
    if parent:
        out["parentSpanId"] = b64(parent)
    return out


def tempo(*groups: tuple[str, list[dict]]) -> dict:
    return {"trace": {"resourceSpans": [
        {"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
         "scopeSpans": [{"spans": spans}]} for service, spans in groups]}}


# The order's trace since R1.5: orders-api's request with its send to MQ, the worker's processing
# under the send, and orders-api's status update under the worker's PUT.
API = [span("SERVER", "POST /orders", "1" * 16, PARENT), span("CLIENT", "INSERT", "2" * 16, "1" * 16),
       span("PRODUCER", "send DEV.QUEUE.1", "6" * 16, "1" * 16), span("CLIENT", "POST", "3" * 16, "6" * 16),
       span("CLIENT", "UPDATE", "4" * 16, "1" * 16), span("CLIENT", "SELECT", "5" * 16, "1" * 16),
       span("SERVER", "PUT /orders/{order_id}/status", "9" * 16, "d" * 16), span("CLIENT", "UPDATE", "8" * 16, "9" * 16)]
WORKER = [span("CONSUMER", "process DEV.QUEUE.1", "c" * 16, "6" * 16),
          span("CLIENT", "PUT", "d" * 16, "c" * 16, url="http://api.mesh:18080/orders/43/status")]
ORDER = API + WORKER



class Browser:
    """Pages that show every expected text, except the dark VictoriaTraces picture when told to fail it."""

    def __init__(self, fail_dark: bool):
        self.fail_dark = fail_dark

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    @property
    def chromium(self):
        return types.SimpleNamespace(launch=lambda: types.SimpleNamespace(new_page=lambda **k: Page(self), close=lambda: None))


class Page:
    def __init__(self, browser: Browser):
        self.browser, self.url = browser, ""

    def goto(self, url, wait_until=None):
        self.url = url

    def fill(self, *args):
        pass

    def click(self, *args):
        pass

    def wait_for_url(self, *args, **kwargs):
        pass

    def wait_for_timeout(self, *args):
        pass

    def close(self):
        pass

    def screenshot(self, path):
        Path(path).write_bytes(b"NEW")

    def get_by_text(self, text, exact=False):
        page = self

        class Locator:
            first = None

            def wait_for(self, timeout):
                if page.browser.fail_dark and "victoriatraces" in page.url and "theme=dark" in page.url:
                    raise TimeoutError(text)

        locator = Locator()
        locator.first = locator
        return locator


def run(path: str, demo: Path, fail_dark: bool):
    """One whole run against fakes: the first read of the order's trace has orders-api's spans only
    (the worker's not exported yet), the second the whole trace."""
    module = load(path, demo)
    ids = iter([TRACE, PARENT + "0" * 16])
    module.uuid = types.SimpleNamespace(uuid4=lambda: types.SimpleNamespace(hex=next(ids)))
    module.place_order = lambda trace_id, parent: 43
    reads = {"tempo": 0}

    def grafana(path, password):
        if "victoriatraces" in path:
            return {"data": [{"spans": [{"spanID": base64.b64decode(s["spanId"]).hex()} for s in ORDER]}]}
        reads["tempo"] += 1
        return tempo(("orders-api", API)) if reads["tempo"] == 1 else tempo(("orders-api", API), ("worker", WORKER))

    module.grafana = grafana
    module.sync_playwright = lambda: Browser(fail_dark)
    out = demo / "shots"
    out.mkdir(exist_ok=True)
    try:
        return module, out, module.main(out), reads
    except SystemExit as stop:
        return module, out, str(stop), reads


def main(path: str) -> int:
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'}  {name}  {detail}".rstrip())

    with tempfile.TemporaryDirectory() as tmp:
        demo = Path(tmp)
        (demo / "secrets").mkdir()
        (demo / "secrets" / "grafana-admin-password").write_text("password\n")
        module = load(path, demo)

        def whole(api: list[dict], worker: list[dict] = WORKER) -> bool:
            return module.whole_order(module.tempo_spans(tempo(("orders-api", api), ("worker", worker))), PARENT)

        check("the whole order trace is taken", whole(API))
        check("a server span under another parent is not",
              not whole([span("SERVER", "POST /orders", "1" * 16, "f" * 16)] + API[1:]))
        check("a trace missing SELECT is not", not whole([s for s in API if s["name"] != "SELECT"]))
        check("SELECT outside the server span does not count",
              not whole([s for s in API if s["name"] != "SELECT"] + [span("CLIENT", "SELECT", "5" * 16, "f" * 16)]))
        check("an extra library span does not fail a whole trace",
              whole(API + [span("INTERNAL", "POST /orders http send", "7" * 16, "1" * 16)]))
        check("orders-api's spans alone are not the whole trace (R1.5)", not whole(API, []))
        check("the worker's processing outside the send does not count",
              not whole(API, [span("CONSUMER", "process DEV.QUEUE.1", "c" * 16, "f" * 16), WORKER[1]]))
        check("one UPDATE does not stand for both, events_sent and the status",
              not whole([s for s in API if s["spanId"] != b64("8" * 16)]))
        check("Tempo's empty answer has no server span",
              module.server_span(module.tempo_spans({"trace": {}}), "orders-api", "POST /orders", PARENT) is None)

        def refuse(*args, **kwargs):
            raise urllib.error.HTTPError("http://grafana", 401, "Unauthorized", {}, io.BytesIO(b""))

        module.urllib.request.urlopen = refuse
        try:
            module.grafana("/api/health", "password")
            check("an HTTP 401 stops with a FAIL line", False, "returned")
        except SystemExit as stop:
            check("an HTTP 401 stops with a FAIL line", str(stop).startswith("FAIL"), str(stop))

        module, out, result, reads = run(path, demo, fail_dark=False)
        line = next((l for l in module.lines if l.startswith("tempo   order trace")), "")
        check("the order trace is taken once the worker's spans are in it",
              reads["tempo"] == 2 and "consumer=1" in line and "producer=1" in line, f"reads={reads['tempo']} {line}")
        check("a whole run writes the four pictures and the record",
              result == 0 and len(list(out.glob("trace-*.png"))) == 4 and module.OUT.read_text().startswith("tempo   order trace"))

        (out / "trace-order-tempo.light.png").write_bytes(b"OLD")
        module.OUT.write_text("OLD\n")
        module, out, result, _ = run(path, demo, fail_dark=True)
        check("a run that fails half-way keeps the last pictures and record",
              str(result).startswith("FAIL") and (out / "trace-order-tempo.light.png").read_bytes() == b"OLD"
              and module.OUT.read_text() == "OLD\n", str(result)[:60])
        check("no staging directory is left behind", not [p for p in out.iterdir() if p.is_dir()])
    print(f"failures: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
