"""Opens VictoriaMetrics' own UI (vmui) from the Mac, light and dark, and checks it works.

Usage: python tests/vmui_capture.py <out-dir>
Two pages: a query of the shop's own traffic (Envoy's requests per application upstream) and
the cardinality explorer. Fails on a page error, any response of 400 or more, or a page missing
its expected text; saves vmui-<page>.<theme>.png either way.
"""
import sys
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import sync_playwright

BASE = "http://victoriametrics.fabric.localtest.me:8080/vmui/"
QUERY = ('sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total'
         '{envoy_cluster_name=~"orders_api_internal|orders_api_tls|mq_web|tcp_svc|web"}[5m]))')
PAGES = {
    # vmui reads the expression from the URL's hash, so it is quoted as one.
    "query": ("#/?g0.expr=" + quote(QUERY, safe="") + "&g0.range_input=30m&g0.relative_time=last_30_minutes&g0.tab=0",
              # Two upstreams busy with no load at all: the worker polls MQ's REST API, and
              # Prometheus scrapes orders-api through orders_api_internal.
              ["orders_api_internal", "mq_web"]),
    "cardinality": ("#/cardinality", ["Total series", "Metric names with the highest number of series"]),
}


def main(out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    problems = 0
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ("light", "dark"):
            for name, (fragment, must) in PAGES.items():
                page = browser.new_page(viewport={"width": 1600, "height": 1000}, color_scheme=theme)
                errors: list[str] = []
                page.on("pageerror", lambda e, errors=errors: errors.append(f"page error: {e}"))
                page.on("response", lambda r, errors=errors: errors.append(f"{r.status} {r.url}")
                        if r.status >= 400 else None)
                page.goto(BASE + fragment, wait_until="networkidle")
                page.wait_for_timeout(4000)
                text = page.inner_text("body")
                missing = [m for m in must if m not in text]
                shot = out_dir / f"vmui-{name}.{theme}.png"
                page.screenshot(path=str(shot))
                ok = not errors and not missing
                problems += not ok
                print(f"{'ok' if ok else 'PROBLEM':8} {shot.name}"
                      + (f"  errors={errors}" if errors else "") + (f"  missing={missing}" if missing else ""))
                page.close()
        browser.close()
    print(f"problems: {problems}")
    return problems


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(min(main(Path(sys.argv[1])), 1))
