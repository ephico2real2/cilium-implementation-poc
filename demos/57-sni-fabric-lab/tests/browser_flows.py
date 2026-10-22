"""Drives the lab's pages like a user and checks what the page shows.

Usage: python tests/browser_flows.py <out-dir> <admin-token-file>
Flows: place an order from the form, ping the TCP service, open the admin portal with the
token, read the API in Swagger UI. Fails on any console error or CSP violation, and saves a
screenshot per step in both colour schemes. TLS is verified separately (scripts/verify.sh,
against the lab CA).
"""
import sys
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

BASE = "https://web.fabric.localtest.me:8443"


def run(out_dir: Path, token: str) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    failures = 0
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for scheme in ("light", "dark"):
            context = browser.new_context(ignore_https_errors=True, color_scheme=scheme,
                                          viewport={"width": 1280, "height": 900})
            page = context.new_page()
            errors: list[str] = []
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(str(e)))

            def step(name: str, action) -> None:
                nonlocal failures
                try:
                    action()
                    print(f"PASS  {scheme:5} {name}")
                except AssertionError as exc:
                    failures += 1
                    print(f"FAIL  {scheme:5} {name}: {str(exc).splitlines()[0][:160]}")
                page.screenshot(path=str(out_dir / f"{name.replace(' ', '-')}.{scheme}.png"), full_page=True)

            page.goto(f"{BASE}/", wait_until="networkidle")

            def place_order():
                page.select_option("select[name=item]", "cortado")
                page.fill("input[name=quantity]", "3")
                page.click("#order-form button")
                expect(page.locator("#order-notice")).to_contain_text("created", timeout=10000)
                expect(page.locator("#orders tr").first).to_contain_text("cortado", timeout=5000)
            step("orders place an order", place_order)

            def ping():
                page.click("#ping")
                expect(page.locator("#ping-notice")).to_contain_text("PONG in", timeout=10000)
            step("orders ping over tcp", ping)

            page.goto(f"{BASE}/admin", wait_until="networkidle")

            def wrong_token():
                page.fill("input[name=token]", "not-the-token")
                page.click("#gate-form button")
                expect(page.locator("#gate-notice")).to_contain_text("refused", timeout=10000)
            step("admin wrong token refused", wrong_token)

            def open_portal():
                page.fill("input[name=token]", token)
                page.click("#gate-form button")
                expect(page.locator("#portal")).to_be_visible(timeout=10000)
                expect(page.locator("#health")).to_contain_text("postgres", timeout=10000)
                expect(page.locator("#admin-orders tr").first).to_be_visible(timeout=10000)
            step("admin portal open", open_portal)

            page.goto("https://api.fabric.localtest.me:8443/docs", wait_until="networkidle")

            def swagger():
                expect(page.locator(".swagger-ui .title")).to_contain_text("orders-api", timeout=10000)
                expect(page.get_by_text("/orders", exact=True).first).to_be_visible(timeout=10000)
            step("swagger", swagger)

            csp = [e for e in errors if "Content Security Policy" in e]
            # A refused token logs a 401 in the console by design; anything else is a problem.
            other = [e for e in errors if e not in csp and "401" not in e]
            if csp or other:
                failures += 1
                print(f"FAIL  {scheme:5} console: csp={len(csp)} other={len(other)}")
                for e in csp + other:
                    print(f"      {e[:200]}")
            else:
                print(f"PASS  {scheme:5} console clean (no CSP violations, no script errors)")
            context.close()
        browser.close()
    return failures


if __name__ == "__main__":
    sys.exit(run(Path(sys.argv[1]), Path(sys.argv[2]).read_text().strip()))
