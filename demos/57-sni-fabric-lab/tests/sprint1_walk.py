"""Walks sprint 1's telemetry in the browser, light and dark, and captures each step.

Usage: python tests/sprint1_walk.py <out-dir> <run> <trace-id>
  <run>       a telemetrygen service name that phase6 sent (verify.sh prints it, e.g. phase6-0a7dc0d0)
  <trace-id>  one of that run's trace ids (also printed by phase6)

Logs in to Grafana as admin through its form, clicks "Test" on every datasource (provisioned ones are read-only, so Grafana shows "Test", not "Save & test"), opens
the run's trace in Tempo (by clicking it in the search results) and in VictoriaTraces, its
metrics in VictoriaMetrics, its log lines in VictoriaLogs, and Prometheus' targets. Each step
must show its expected text, or the walk fails and names the step: a screenshot of an empty
page is never taken as evidence.
"""
import json
import sys
import urllib.parse
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

DEMO = Path(__file__).resolve().parent.parent
GRAFANA = "http://grafana.fabric.localtest.me:8080"
PROMETHEUS = "http://prometheus.fabric.localtest.me:8080"
OUT_DIR = Path(".")
DATASOURCES = [  # uid, the text its health check shows when it works
    ("prometheus", "Successfully queried the Prometheus API"),
    ("victoriametrics", "Successfully queried the Prometheus API"),
    ("victorialogs", "Data source is working"),
    ("tempo", "Data source is working"),
    ("victoriatraces", "Data source is working"),
]


def explore(theme: str, uid: str, ds_type: str, query: dict) -> str:
    pane = {"datasource": uid, "queries": [{"refId": "A", "datasource": {"type": ds_type, "uid": uid}, **query}],
            "range": {"from": "now-15m", "to": "now"}}
    panes = urllib.parse.quote(json.dumps({"a": pane}, separators=(",", ":")))
    return f"{GRAFANA}/explore?schemaVersion=1&orgId=1&theme={theme}&panes={panes}"


def expect(page: Page, step: str, texts: list[str], timeout_ms: int = 20000) -> None:
    for text in texts:
        try:
            page.get_by_text(text, exact=False).first.wait_for(timeout=timeout_ms)
        except Exception as error:
            # What the page showed instead is the first thing to look at, so keep it beside the output.
            failed = OUT_DIR / f"FAILED-{step.replace(' ', '-')}.png"
            page.screenshot(path=str(failed))
            raise SystemExit(f"FAIL  {step}: '{text}' did not appear ({type(error).__name__}); page: {failed}") from None


def shot(page: Page, out_dir: Path, name: str, theme: str, full_page: bool = False) -> None:
    page.wait_for_timeout(1500)  # let charts and fonts settle after the expected text appears
    path = out_dir / f"{name}.{theme}.png"
    page.screenshot(path=str(path), full_page=full_page)
    print(f"PASS  {name}.{theme}.png")


def walk(page: Page, out_dir: Path, theme: str, run: str, trace_id: str) -> None:
    password = (DEMO / "secrets" / "grafana-admin-password").read_text().strip()
    page.goto(f"{GRAFANA}/login?theme={theme}", wait_until="load")
    page.fill("input[name=user]", "admin")
    page.fill("input[name=password]", password)
    shot(page, out_dir, "01-grafana-login", theme)
    page.click("button[type=submit]")
    page.wait_for_url(lambda url: "/login" not in url, timeout=20000)

    page.goto(f"{GRAFANA}/connections/datasources?theme={theme}", wait_until="load")
    expect(page, "datasource list", ["Prometheus", "VictoriaMetrics", "VictoriaLogs", "Tempo", "VictoriaTraces"])
    shot(page, out_dir, "02-datasources", theme)

    for n, (uid, healthy) in enumerate(DATASOURCES, start=3):
        page.goto(f"{GRAFANA}/connections/datasources/edit/{uid}?theme={theme}", wait_until="load")
        page.get_by_role("button", name="Test", exact=True).click()
        expect(page, f"test {uid}", [healthy])
        page.get_by_text(healthy).first.evaluate("e => e.scrollIntoView({block: 'center'})")
        shot(page, out_dir, f"{n:02d}-datasource-{uid}", theme)

    # Tempo: search the run's traces, then open one by clicking its id in the results.
    page.goto(explore(theme, "tempo", "tempo", {"queryType": "traceql", "query": f'{{resource.service.name="{run}"}}'}),
              wait_until="load")
    expect(page, "tempo search", [trace_id[:12]])
    shot(page, out_dir, "08-tempo-search", theme)
    page.get_by_text(trace_id[:12]).first.click()
    expect(page, "tempo trace", ["lets-go", "okey-dokey"])
    shot(page, out_dir, "09-tempo-trace", theme)

    page.goto(explore(theme, "victoriatraces", "jaeger", {"queryType": "", "query": trace_id}), wait_until="load")
    expect(page, "victoriatraces trace", ["lets-go", "okey-dokey"])
    shot(page, out_dir, "10-victoriatraces-trace", theme)

    page.goto(explore(theme, "victoriametrics", "prometheus", {"expr": f'{{"service.name"="{run}"}}'}),
              wait_until="load")
    expect(page, "victoriametrics series", [run])
    shot(page, out_dir, "11-victoriametrics-metrics", theme)

    page.goto(explore(theme, "victorialogs", "victoriametrics-logs-datasource",
                      {"expr": f'trace_id:="{trace_id}"', "queryType": "instant"}), wait_until="load")
    # The service name sits in the collapsed "Common labels"; the line count is what shows.
    expect(page, "victorialogs lines", ["5 lines displayed"])
    shot(page, out_dir, "12-victorialogs-lines", theme)

    page.goto(f"{PROMETHEUS}/targets?theme={theme}", wait_until="load")
    expect(page, "prometheus targets", ["tempo", "victoria-traces", "victoria-metrics", "victoria-logs", "otel-collector"])
    shot(page, out_dir, "13-prometheus-targets", theme, full_page=True)  # the store jobs are below the fold


def main(out_dir: Path, run: str, trace_id: str) -> int:
    global OUT_DIR
    OUT_DIR = out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ("light", "dark"):
            context = browser.new_context(viewport={"width": 1600, "height": 1000}, color_scheme=theme)
            walk(context.new_page(), out_dir, theme, run, trace_id)
            context.close()
        browser.close()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(Path(sys.argv[1]), sys.argv[2], sys.argv[3]))
