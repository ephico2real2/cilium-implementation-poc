"""Captures the lab dashboard in Grafana, light and dark, as an anonymous viewer, and checks it.

Usage: python tests/grafana_capture.py <out-dir> [datasource-uid]
With a datasource uid (prometheus or victoriametrics), the dashboard is opened on that datasource
outside kiosk mode, so the Datasource menu shows the choice, and the menu must show its name.
Fails when any panel shows "No data", "NaN", an error, or when a panel did not render. The
viewport is tall enough for every panel to load without scrolling (Grafana loads panels lazily).
"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://grafana.fabric.localtest.me:8080/d/sni-fabric-lab/sni-fabric-lab?orgId=1&from=now-15m&to=now&theme={theme}"
NAMES = {"prometheus": "Prometheus", "victoriametrics": "VictoriaMetrics"}
BAD = ["No data", "NaN", "not found", "Error", "Forbidden"]
# The dashboard counts as loaded only if these appear: its title, and a chart from each end.
# (kiosk mode hides the dashboard's own title, so only chart titles are checked)
MUST = ["Each component, now", "New connections per tenant", "Queue manager: recovery log", "tcp-svc: commands"]


def main(out_dir: Path, datasource: str | None) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    problems = 0
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ("dark", "light"):
            page = browser.new_page(viewport={"width": 1600, "height": 3400})
            url = URL.format(theme=theme) + (f"&var-datasource={datasource}" if datasource else "&kiosk")
            page.goto(url, wait_until="networkidle")
            page.wait_for_timeout(6000)
            text = page.inner_text("body")
            found = [word for word in BAD if word in text]
            missing = [title for title in MUST if title not in text]
            if datasource and NAMES[datasource] not in text:
                missing.append(f"the Datasource menu showing {NAMES[datasource]}")
            shot = out_dir / (f"grafana-dashboard-{datasource}.{theme}.png" if datasource else f"grafana-dashboard.{theme}.png")
            page.screenshot(path=str(shot), full_page=True)
            status = "ok" if not found and not missing else "PROBLEM"
            problems += bool(found or missing)
            print(f"{status:8} {theme:5} flagged words: {found or 'none'}  missing: {missing or 'none'}  -> {shot.name}")
            page.close()
        browser.close()
    return problems


if __name__ == "__main__":
    uid = sys.argv[2] if len(sys.argv) > 2 else None
    if uid is not None and uid not in NAMES:
        sys.exit(f"unknown datasource uid {uid!r}; one of: {', '.join(NAMES)}")
    sys.exit(main(Path(sys.argv[1]), uid))
