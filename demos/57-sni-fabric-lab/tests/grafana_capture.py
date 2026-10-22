"""Captures the lab dashboard in Grafana, light and dark, as an anonymous viewer, and checks it.

Usage: python tests/grafana_capture.py <out-dir>
Fails when any panel shows "No data", "NaN", an error, or when a panel did not render. The
viewport is tall enough for every panel to load without scrolling (Grafana loads panels lazily).
"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://grafana.fabric.localtest.me:8080/d/sni-fabric-lab/sni-fabric-lab?orgId=1&from=now-15m&to=now&kiosk&theme={theme}"
BAD = ["No data", "NaN", "not found", "Error", "Forbidden"]
# The dashboard counts as loaded only if these appear: its title, and a chart from each end.
# (kiosk mode hides the dashboard's own title, so only chart titles are checked)
MUST = ["Each component, now", "New connections per tenant", "Queue manager: recovery log", "tcp-svc: commands"]


def main(out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    problems = 0
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ("dark", "light"):
            page = browser.new_page(viewport={"width": 1600, "height": 3400})
            page.goto(URL.format(theme=theme), wait_until="networkidle")
            page.wait_for_timeout(6000)
            text = page.inner_text("body")
            found = [word for word in BAD if word in text]
            missing = [title for title in MUST if title not in text]
            shot = out_dir / f"grafana-dashboard.{theme}.png"
            page.screenshot(path=str(shot), full_page=True)
            status = "ok" if not found and not missing else "PROBLEM"
            problems += bool(found or missing)
            print(f"{status:8} {theme:5} flagged words: {found or 'none'}  missing: {missing or 'none'}  -> {shot.name}")
            page.close()
        browser.close()
    return problems


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
