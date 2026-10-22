"""Structural tests for the lab dashboard, in both forms (diagram-kit dashboard standard, section 9).

Usage: python tests/test_dashboard.py [grafana.json] [perses.json]
Checks: the sections and charts are there in order; every chart has a description, a unit, a
legend below and line width 1; every line has its own fixed colour from the Tableau 10 set,
the second dashed and the third dotted; every rate uses the fixed [5m] window and says so;
the Prometheus datasource is the default dashboard variable and every chart uses it; and the
Perses form carries the same colours, line styles, units and legends.
Exits non-zero on the first failure, naming it.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRAFANA = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "observability/grafana/dashboards/fabric.json"
PERSES = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "observability/perses/fabric.json"

PALETTE = {"#4e79a7", "#e15759", "#edc948", "#b07aa1", "#59a14f", "#f28e2b", "#76b7b2"}
SECTIONS = [
    "Is every part of the lab up?",
    "Who uses the shared TLS port?",
    "Do calls between services fail, and do Envoy's retries save them?",
    "Are orders flowing end to end?",
    "Is it fast?",
    "Is IBM MQ busy and healthy?",
    "Are Postgres and the TCP service answering?",
]
FIRST_CHARTS = ["Each component, now", "Each component, over time", "New connections per tenant (per second)"]

failures: list[str] = []


def expect(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


grafana = json.loads(GRAFANA.read_text())
perses = json.loads(PERSES.read_text())
panels = grafana["panels"]
charts = [p for p in panels if p["type"] not in ("row", "text")]

variables = grafana.get("templating", {}).get("list", [])
datasource_variables = [v for v in variables if v.get("name") == "datasource"]
expect(len(datasource_variables) == 1, "expected one datasource variable named datasource")
if datasource_variables:
    variable = datasource_variables[0]
    expect(variable.get("type") == "datasource" and variable.get("query") == "prometheus",
           "datasource variable is not a Prometheus datasource picker")
    current = variable.get("current", {})
    expect(current.get("text") == "Prometheus" and current.get("value") == "prometheus",
           "datasource variable does not default to Prometheus (uid prometheus)")

expect([p["title"] for p in panels if p["type"] == "row"] == SECTIONS, "sections differ from the expected seven, in order")
expect(len(charts) == 14, f"expected 14 charts, found {len(charts)}")
expect([c["title"] for c in charts[:3]] == FIRST_CHARTS, "the first three charts changed")

for chart in charts:
    name = chart["title"]
    expect(chart.get("datasource") == {"type": "prometheus", "uid": "${datasource}"},
           f"{name}: panel datasource is not $datasource")
    for panel_target in chart.get("targets", []):
        expect(panel_target.get("datasource") == {"type": "prometheus", "uid": "${datasource}"},
               f"{name} {panel_target.get('refId', '?')}: target datasource is not $datasource")
    expect(len(chart.get("description", "")) > 40, f"{name}: description missing or too short")
    if chart["type"] != "timeseries":
        continue
    defaults = chart["fieldConfig"]["defaults"]
    expect(bool(defaults.get("unit")), f"{name}: no unit")
    expect(defaults["custom"]["lineWidth"] == 1, f"{name}: line width is not 1")
    expect(chart["options"]["legend"]["placement"] == "bottom", f"{name}: legend not below the chart")
    overrides = {o["matcher"]["options"]: o["properties"] for o in chart["fieldConfig"]["overrides"]}
    for index, target in enumerate(chart["targets"]):
        props = {p["id"]: p["value"] for p in overrides.get(target["refId"], [])}
        color = props.get("color", {})
        expect(color.get("mode") == "fixed" and color.get("fixedColor") in PALETTE,
               f"{name} {target['refId']}: no fixed palette colour")
        style = props.get("custom.lineStyle", {}).get("fill")
        expect(style == {1: "dash", 2: "dot"}.get(index % 3), f"{name} {target['refId']}: line style {style}")
        windows = set(re.findall(r"\[(\w+)\]", target["expr"]))
        expect(windows <= {"5m"}, f"{name} {target['refId']}: rate window {windows}, not [5m]")
        if "rate(" in target["expr"]:
            expect("5m" in chart["description"], f"{name}: uses rate() but does not state the 5m window")

# The Perses form: same charts, same colours and styles, query by query.
perses_panels = [perses["panels"][item["content"]["$ref"].rsplit("/", 1)[-1]]
                 for layout in perses["layouts"] for item in layout["spec"]["items"]]
perses_charts = [p for p in perses_panels if p["spec"]["plugin"]["kind"] != "Markdown"]
expect(len(perses_charts) == len(charts), f"Perses has {len(perses_charts)} charts, Grafana {len(charts)}")
for chart, converted in zip(charts, perses_charts):
    name = chart["title"]
    expect(converted["spec"]["display"]["name"] == name, f"Perses chart order differs at {name}")
    if chart["type"] != "timeseries":
        continue
    spec = converted["spec"]["plugin"]["spec"]
    expect(spec["visual"]["lineWidth"] == 1, f"Perses {name}: line width")
    expect(spec["legend"]["position"] == "bottom", f"Perses {name}: legend position")
    expect(bool(spec.get("yAxis", {}).get("format", {}).get("unit")), f"Perses {name}: unit dropped")
    settings = {s["queryIndex"]: s for s in spec.get("querySettings", [])}
    overrides = {o["matcher"]["options"]: o["properties"] for o in chart["fieldConfig"]["overrides"]}
    for index, target in enumerate(chart["targets"]):
        props = {p["id"]: p["value"] for p in overrides[target["refId"]]}
        setting = settings.get(index, {})
        expect(setting.get("colorValue") == props["color"]["fixedColor"], f"Perses {name} query {index}: colour")
        want = {1: "dashed", 2: "dotted"}.get(index % 3)
        expect(setting.get("lineStyle") == want, f"Perses {name} query {index}: line style {setting.get('lineStyle')}")

if failures:
    print("FAIL")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1)
print(f"PASS  {len(charts)} charts in {len(SECTIONS)} sections; both forms agree on colours, styles, units, legends")
