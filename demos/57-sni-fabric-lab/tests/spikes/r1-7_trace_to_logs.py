"""Spike for R1.7 (#111): does Grafana's Tempo datasource link a span to its logs in VictoriaLogs?

Usage: python tests/spikes/r1-7_trace_to_logs.py   (from the demo directory, against the running lab)
Needs Playwright with Chromium (diagram-kit's environment). Takes the trace id phase 6 last
recorded in output/transcript.txt, whose log lines carry the same trace_id. Creates a temporary
Tempo datasource with tracesToLogsV2 pointing at the provisioned VictoriaLogs (the provisioned
Tempo datasource is read-only), opens the trace in Explore, clicks a span, follows "Logs for this
span", and reads the logs pane the link opened: the run's lines, or Grafana's "No logs found.";
anything else is UNKNOWN and fails the run. The temporary datasource, and the Explore query
history the run wrote, are deleted on any exit; a failed deletion fails the run.
Two settings are measured: Grafana's defaults, and service.name mapped to its own name.
Writes output/spike-r1-7-trace-to-logs.txt and a light picture of each case's logs pane.
"""
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

DEMO = Path(__file__).resolve().parent.parent.parent
GRAFANA = "http://grafana.fabric.localtest.me:8080"
UID = "spike-r1-7-tempo"
OUT = DEMO / "output" / "spike-r1-7-trace-to-logs.txt"
lines: list[str] = []


def say(line: str) -> None:
    print(line)
    lines.append(line)


def api(method: str, path: str, password: str, body: dict | None = None) -> tuple[int, dict]:
    request = urllib.request.Request(f"{GRAFANA}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
    request.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{password}".encode()).decode())
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def main() -> int:
    password = (DEMO / "secrets" / "grafana-admin-password").read_text().strip()
    found = re.findall(r"with trace_id ([0-9a-f]{32})", (DEMO / "output" / "transcript.txt").read_text())
    if not found:
        say("verdict UNKNOWN: no phase 6 trace id in output/transcript.txt")
        OUT.write_text("\n".join(lines) + "\n")
        return 1
    trace_id = found[-1]
    say(f"trace   {trace_id} (phase 6's last run, from output/transcript.txt)")
    # Two settings, each with what it is expected to do. Grafana's default tags put service.name in
    # the query as service_name (Loki's form); VictoriaLogs keeps the field's dotted name.
    cases = [
        ("defaults", {}, False),
        ("service.name mapped to its own name", {"tags": [{"key": "service.name", "value": "service.name"}]}, True),
    ]
    unexpected = 0
    for label, extra, want in cases:
        got = follow(password, trace_id, label, extra)
        ok = got == want
        unexpected += not ok
        verdict = {True: "LINKED", False: "NOT LINKED", None: "UNKNOWN (a step failed)"}[got]
        say(f"verdict {label}: {verdict} ({'as expected' if ok else 'UNEXPECTED'})")
    OUT.write_text("\n".join(lines) + "\n")
    return 1 if unexpected else 0


def follow(password: str, trace_id: str, label: str, extra: dict) -> bool | None:
    """One temporary Tempo datasource with these trace-to-logs settings: True if the run's lines
    show in the logs pane the link opened, False if that pane says "No logs found.", None if a
    step or the cleanup failed, or the pane shows neither (then no verdict is claimed)."""
    api("DELETE", f"/api/datasources/uid/{UID}", password)  # a leftover from an interrupted run
    started_ms = (int(time.time()) - 1) * 1000
    settings = {"datasourceUid": "victorialogs", "filterByTraceID": True,
                "spanStartTimeShift": "-5m", "spanEndTimeShift": "5m", **extra}
    status, _ = api("POST", "/api/datasources", password, {
        "name": UID, "uid": UID, "type": "tempo", "access": "proxy", "url": "http://tempo.mesh:18080",
        "jsonData": {"tracesToLogsV2": settings}})
    say(f"case    {label}: datasource {UID} created, HTTP {status}")
    if status != 200:
        return None
    shot = DEMO / "output" / f"spike-r1-7-trace-to-logs.{'mapped' if extra else 'defaults'}.light.png"
    found = None
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 1600, "height": 1000}, color_scheme="light")
            page.goto(f"{GRAFANA}/login?theme=light", wait_until="load")
            page.fill("input[name=user]", "admin")
            page.fill("input[name=password]", password)
            page.click("button[type=submit]")
            page.wait_for_url(lambda url: "/login" not in url, timeout=20000)
            pane = {"datasource": UID, "range": {"from": "now-24h", "to": "now"},
                    "queries": [{"refId": "A", "datasource": {"type": "tempo", "uid": UID},
                                 "queryType": "traceql", "query": trace_id}]}
            panes = urllib.parse.quote(json.dumps({"a": pane}, separators=(",", ":")))
            page.goto(f"{GRAFANA}/explore?schemaVersion=1&orgId=1&theme=light&panes={panes}", wait_until="load")
            page.get_by_text("lets-go", exact=True).first.click(timeout=30000)
            link = page.get_by_text("Logs for this span", exact=False).first
            link.wait_for(timeout=20000)
            link.click()
            # The link opens VictoriaLogs in a second Explore pane (each pane is a
            # data-testid="data-testid Explore" container); everything below is read in that pane.
            logs_pane = page.get_by_test_id("data-testid Explore").nth(1)
            logs_pane.get_by_text("trace_id:=", exact=False).first.wait_for(timeout=20000)
            # The query Grafana built, from that pane's editor; the editor wraps it on screen, so
            # its lines are joined back.
            query = logs_pane.locator(".monaco-editor .view-lines").last.inner_text()
            say(f"query   {''.join(query.split(chr(10))).replace(chr(160), ' ')}")
            try:
                logs_pane.get_by_text("the message", exact=False).first.wait_for(timeout=20000)
                found = True
            except Exception:
                # Not linked only when Grafana itself says so in this pane; an error is no verdict.
                # The text shares its element with the "Scan for older logs" button: match a pattern.
                empty = logs_pane.get_by_text(re.compile(r"No logs found")).first
                found = False if empty.is_visible() else None
            page.wait_for_timeout(1500)
            page.screenshot(path=str(shot))
            shown = {True: "phase 6 lines shown", False: "No logs found", None: "neither lines nor No logs found"}
            say(f"logs    {shown[found]}; picture: output/{shot.name}")
            browser.close()
    except Exception as error:
        say(f"step failed: {type(error).__name__}: {str(error).splitlines()[0]}")
        found = None
    finally:
        status, _ = api("DELETE", f"/api/datasources/uid/{UID}", password)
        say(f"case    {label}: datasource deleted, HTTP {status}")
        # Explore saved this case's queries in admin's query history; each names the trace id.
        _, history = api("GET", f"/api/query-history?searchString={trace_id}&from={started_ms}&limit=100",
                         password)
        rows = (history.get("result") or {}).get("queryHistory") or []
        removed = sum(api("DELETE", f"/api/query-history/{row['uid']}", password)[0] == 200 for row in rows)
        say(f"case    {label}: Explore query history removed, {removed} of {len(rows)}")
        if status not in (200, 404) or removed != len(rows):
            say(f"case    {label}: cleanup incomplete, so no verdict")
            found = None
    return found


if __name__ == "__main__":
    sys.exit(main())
