# Demo 38 — Grafana's visual grammar: the right chart for the question, colours that mean something, and how a dashboard grows

A tutorial, not a Cilium demo. It builds six small dashboards on the lab's Grafana (13.2.1) from data every Kubernetes
cluster has — a node's CPU, memory and network from node_exporter; pod, deployment and restart counts from
kube-state-metrics — and works up, one idea per section, to the Hubble metrics and the observer dashboard the rest of
this repository is about. Every panel carries a caption saying what it is for, and every section ends with the
Grafana documentation page and the video to watch next. A junior engineer with a browser and `kubectl` can follow it
top to bottom in an afternoon; nothing here needs Cilium until §6.

| | |
|---|---|
| **Build** | `python3 demos/38-grafana-visual-grammar/build.py` → `dashboards/tut-*.json` (six files, generated, never hand-edited) |
| **Provision** | `demos/38-grafana-visual-grammar/provision.sh` — ConfigMaps the Grafana sidecar loads into the *Tutorial* folder |
| **Prove** | `demos/38-grafana-visual-grammar/check.sh` — every panel's query run against Prometheus, `N series` per panel |
| **Capture** | `PW=… NODE_PATH=$PWD/.tmp/pw/node_modules node demos/38-grafana-visual-grammar/capture.js` → `output/screenshots/` |
| **Open** | `https://grafana.poc.local/dashboards?tag=tutorial` |

## 0. Before you start — what a panel is

A Grafana panel is three things stacked: a **query** (PromQL here) that returns series or a table; a **reduction**
of that data to what the visualization can draw (one number, one number per series, every row); and a
**visualization** with its field options (unit, thresholds, colours, mappings, overrides). Most dashboard mistakes are
a mismatch between two of the three — a ranking drawn as a pie, a count coloured like a temperature, a range query
where the chart wanted one table. The sections follow that order: the question (§1), the reduction (§2), the colour
(§3), the words (§4), the growth (§5), and then the Cilium case (§6).

**Learn more** — [Panels and visualizations](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/) (docs);
the lab's Grafana is demo 16's kube-prometheus-stack, the metrics come from node_exporter and kube-state-metrics, both
installed by that chart.

## 1. The question decides the chart — `tut-1-question`

Seven questions, seven visualizations, all from one Linux node's exporter. Read the caption under each panel, then
change the `node` variable and watch which panels change shape and which only change numbers.

| The question | The chart | The panel | Why this one |
|---|---|---|---|
| What is it **now**? | **Stat** | CPU busy % per node, sparkline | one number per series, coloured by threshold; the sparkline is the trend without a second panel |
| How far from the **limit**? | **Gauge** | memory used % | a gauge needs a real ceiling (100 % of RAM); without one it is decoration |
| What happened, and **when**? | **Time series** | load average per node | the default for anything with a time axis; one line per series, named in the legend |
| What **share** of a whole? | **Pie** | CPU time by mode on `$node` | the slices add up to one CPU's time and there are ≤ 6 of them — the one case a pie is right |
| Who is **biggest**? | **Bar gauge** | network receive by interface, top 5 | a ranking is a comparison between categories: bars sorted, the number beside each name, one colour |
| Which **state**, for how long? | **State timeline** | node_exporter `up` | discrete states over time; the colour band's length is the duration |
| Every **row**? | **Table** | `node_uname_info` | when the reader needs the facts, not a shape — hide the columns that carry nothing |

Grafana's own wording: a pie is for "data that adds up to a total and you want to show the proportion of each
value compared to other slices, as well as to the whole"; bar charts are what it recommends for categorical
comparisons; a gauge shows "how far a single metric is from a threshold"; a stat is "for big stats and optional
sparkline". Hold every panel you build to that table.

**Try it.** Edit the pie (panel menu → Edit) and change *Value options → Show* from *Calculate* to *All values*: the
legend fills with timestamps, because a range query has many values per series. Put it back. Then edit the bar gauge
and switch its query from *Instant* to *Range*: the bars stop sorting — §2 says why.

**Learn more** — docs: [Stat](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/stat/),
[Gauge](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/gauge/),
[Bar gauge](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/bar-gauge/),
[Pie chart](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/pie-chart/),
[State timeline](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/state-timeline/),
[Table](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/table/).
Videos (Grafana Labs, short beginner format, 5–10 min each): [Visualizing Gauges](https://www.youtube.com/watch?v=QwXj3y_YpnE),
[Visualizing Bar Gauges](https://www.youtube.com/watch?v=7PhDysObEXA), [Visualizing Pie Charts](https://www.youtube.com/watch?v=A_lDhM9w4_g);
longer: [Deep dive — Time series panel](https://www.youtube.com/watch?v=RKtW87cPxsw), [Deep dive — Table panel](https://www.youtube.com/watch?v=PCY7O8EJeJY).

## 2. Instant, range, reduce — the same query, four answers — `tut-2-time`

A **range** query returns a series per label set over the time range; an **instant** query returns one table of the
current values. A visualization that draws one number per series must **reduce** each series (Grafana calls it
*Calculate*: last, mean, max…); one that draws rows takes the table as it is (*All values*). Six panels show the same
`count by (namespace) (kube_pod_info)` reduced differently, and the two pies that look identical are not:

- *Range + last value* and *Range + mean*: the same series, two reducers, two different numbers. The reducer is part
  of the question — say which one you show.
- *Instant + All values* and *Range + Calculate*: same counts, but the first colours **equal counts alike** — Grafana
  colours the rows of one field by value, so `team-a` and `team-b`, two pods each, share a colour. This is exactly
  what the observer dashboard did before today (§6). The second shape — one series per name — gives one colour per
  name. Prefer it for pies and legends. (Both pies are filtered to five namespaces on purpose: a 25-slice pie teaches
  nothing but that pies stop at six.)
- `rate()` over `$__rate_interval` and over a fixed `[1m]`: zoom to seven days; the fixed window thins out (a 1-minute
  window over a 30-second scrape has one or two samples per step), the adaptive one stays continuous.

**Try it.** Scale a deployment so two namespaces have the same pod count; watch the left pie merge their colours and
the right one keep them apart.

**Learn more** — docs: [Query and transform data](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/query-transform-data/),
[Calculation types](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/query-transform-data/calculation-types/),
[Prometheus query editor — instant vs range](https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/),
[`$__rate_interval`](https://grafana.com/docs/grafana/latest/datasources/prometheus/template-variables/#use-__rate_interval);
community thread that matches the measurement: [pie chart shows identical colours for different labels](https://community.grafana.com/t/pie-chart-shows-identitical-colors-for-different-labels/100320).

## 3. Colour that means something — `tut-3-colour`

Colour is the loudest channel on a dashboard, so it must carry **one** thing. Grafana gives you three ways to assign
it, and the mistake is mixing them:

| Colour encodes | Mechanism | The panel | Rule |
|---|---|---|---|
| a **category's identity** | fixed colour per name — `overrides` with a `byName` (or `byRegexp`) matcher | *Pod phases*: Running green, Pending yellow, Failed red | the same meaning has the same colour on every dashboard, every load; never rely on palette position for a category people recognise |
| a **quantity on a scale** | thresholds, or a continuous scheme | *Deployments available/desired*: red → orange at 90 % → green at 100 %; *Restarts* table with cell background | thresholds are for numbers; a threshold on a category is noise |
| **nothing** (the shape already carries the value) | one fixed colour | *Pods per namespace* bar gauge | a colour per namespace would change every time a namespace appears and mean nothing |

**When new items appear.** Two palette modes for open-ended categories, and what each does was **measured** on this
Grafana (13.2.1) rather than read from the option's name:

| Visualization | `palette-classic` (by index) | `palette-classic-by-name` |
|---|---|---|
| time series | every line its own colour — until a series is added and the colours shift | **works**: a name keeps its colour as others come and go (17 distinct colours for 25 namespaces — the palette has about twenty, so unrelated names can collide) |
| pie, bar gauge, stat | one colour per series by order — the same shifting | **one colour for every series** (a 25-slice pie all cyan; a bar gauge with 2 distinct colours in 50 swatches) — [grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275), closed as not planned |

So: for a **time series** whose series come and go, by-name is the right default; for a **pie, stat or bar gauge**,
by-name is not an option — fix the colour per name with an override for categories that have a meaning (verdicts,
phases, drop reasons), and for open-ended rankings use one colour and let the length speak (§1). The dashboard shows
all four cases side by side on five namespaces.

**Try it.** Create a namespace named `aaa-test` with one pod and reload: the by-index pie and time series recolour;
the by-name time series adds one line and keeps the others' colours; the by-name pie stays one colour.

**Learn more** — docs: [Configure standard options — color scheme](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-standard-options/),
[Configure thresholds](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-thresholds/),
[Configure value mappings](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-value-mappings/),
[Configure field overrides](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-overrides/);
the by-name palette's history: [grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275).

## 4. Units, legends, captions — the words — `tut-4-meaning`

The same time series three times: raw; with a unit and a named legend; with a title that says what and in which unit,
a hover description that says where the data comes from, and a caption that says what "normal" looks like. The third
is the only one a stranger can read. Meaning is added in words, not colours; the checklist at the bottom of the
dashboard is the one this lab applies to every panel it ships:

- the title says **what** and the **unit**;
- the unit is set (`Bps`, `percent`, `short`) — Grafana scales it (`1.2 MB/s`) and the reader stops counting zeros;
- the legend names the series (`{{instance}}`, not `{__name__=…}`), and shows the calculation that matters (mean, max);
- the description says the **source** and the **window** (node_exporter, `rate` over 5 m);
- a caption under the panel says what normal looks like and **what an empty panel means**;
- colours mean one thing (§3).

The captions are transparent **text panels** in markdown, two grid rows high, under each panel — a `description` only
shows on hover, and the reader who needs it most never hovers. One trap, measured while building this: an HTML comment
on the same line as the text (`<!-- marker -->**bold**`) makes CommonMark treat the line as an HTML block and the
markdown renders raw; put the marker on its own line.

**Learn more** — docs: [Configure standard options — units](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-standard-options/#unit),
[Configure legends](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-legend/),
[Text panel](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/text/).

## 5. Grow it — variables, repeats, links, code — `tut-5-grow`

One dashboard for every cluster and namespace, not one copy per cluster: a `cluster` variable (`label_values(kube_node_info, cluster)`),
a `namespace` variable that depends on it, a **row repeated per cluster** stamping the same three panels for poc1 and
poc2, and **links** that hold the tutorial together (a dropdown of every dashboard tagged `tutorial`, a link to the
observer dashboard). Growth rules this lab follows:

1. **Add a variable, not a copy.** When the second cluster came (demo 22), every dashboard here gained `cluster`
   instead of a twin.
2. **Generate, do not hand-edit.** All six dashboards come from `build.py`; the observer dashboard's redesign is
   `demos/25-hubble-observer-loki/dashboard-design.py`; the app-keyed L7 dashboard is a script over the chart's file.
   A generator is idempotent, diffable and reviewable; a JSON export is none of those.
3. **Provision as code.** A ConfigMap with `grafana_dashboard: "1"` and a folder annotation — the sidecar does the
   rest (`provision.sh`; the same mechanism as demo 16).
4. **Prove it with the API, not with your eyes.** `check.sh` runs every panel's query and prints the series count;
   `capture.js` reads the rendered captions back and fails if any is raw markdown. A dashboard that says "No data" in a
   screenshot nobody looked at is a dashboard that lies.
5. **Version it.** Dashboards live next to the code that produces the data, in the same pull request.

**Learn more** — docs: [Variables](https://grafana.com/docs/grafana/latest/visualizations/dashboards/variables/),
[Repeat panels or rows](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/create-dashboard/#configure-repeating-rows),
[Manage dashboard links](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/manage-dashboard-links/),
[Provision dashboards](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards);
video: [How to create and work with variables (Grafana Labs)](https://www.youtube.com/watch?v=mMUJ3iwIYwc).

## 6. Now Cilium — `tut-6-cilium` and the observer dashboard

The same grammar on Hubble's Prometheus metrics: **flows/s per cluster** as a stat with a sparkline (the pulse);
**flows/s by verdict** as a time series with fixed colours — DROPPED is red on every Cilium dashboard in this lab,
FORWARDED green, REDIRECTED blue, AUDIT yellow; **drops/s by reason** as a sorted bar gauge in one colour (a ranking:
`POLICY_DENIED` first means policy is doing its job; anything else first means something is broken).

Then read the observer dashboard (`/d/hubble-observer-23862`) with this tutorial's eyes: it is the same grammar on
**Loki flow logs** — a stat for the count, pies for the ≤ 6-way splits with fixed colours per meaning, bar gauges for
the two rankings, a time series for the rate, a caption under each. It got there by exactly the mistakes of §2 and §3:
three pies on an instant query with *All values* coloured equal counts alike (28 % / 28 % both `rgb(87,148,242)`,
measured from the DOM), and the panels meant nothing to a reader until the captions said "every panel here counts
drops". The research behind that redesign, field by field from Cilium's `flow.proto`, is
[`docs/OBSERVER-DASHBOARD-PANELS.md`](../../docs/OBSERVER-DASHBOARD-PANELS.md); the L7 dashboard's own blind spot and
its app-keyed fix is [`docs/HUBBLE-L7-LABELS.md`](../../docs/HUBBLE-L7-LABELS.md).

**Learn more** — [Cilium: running Prometheus and Grafana](https://docs.cilium.io/en/stable/observability/grafana/),
[Hubble metrics reference](https://docs.cilium.io/en/stable/observability/metrics/); demo 16 (the stack), demo 25
(the observer), demo 26 (the verdict dashboards).

## 7. What to take away

- **The question decides the chart.** Now → stat; limit → gauge; when → time series; share of ≤ 6 → pie; ranking →
  sorted bars; state → state timeline; rows → table.
- **The reduction is part of the question.** Last, mean or max; instant table or range series — say which.
- **Colour carries one thing**: identity (fixed per name), quantity (thresholds), or nothing (one colour). New items
  get stable colours by name on a time series only; in a pie, stat or bar gauge write the override.
- **Meaning is words**: unit, legend, description, caption. A panel that needs a hover to be understood is unfinished.
- **Grow with variables and generators**, prove with the API, version with the code.

## Evidence (2026-09-17, poc1 + poc2, Grafana 13.2.1)

- `provision.sh`: six ConfigMaps, all six uids answered by the API within the sidecar's poll — `tut-1-question` 15
  panels, `tut-2-time` 12, `tut-3-colour` 16, `tut-4-meaning` 7, `tut-5-grow` 8, `tut-6-cilium` 7 (captions counted).
- `check.sh`: **30 panels, every one with data, 0 `NO DATA`** — e.g. CPU busy 4 series (two nodes × two clusters),
  CPU by mode 8, network top 5 → 5, the five filtered namespaces → 5, pod phases 5, flows/s by verdict 3, drops by
  reason 3.
- `capture.js`: six screenshots under [`output/screenshots/`](output/screenshots/), 31 captions read back as rendered
  markdown (none raw), the state timeline's legend says `UP`; exit 0.
- Measured while building, and now part of the lessons: the by-name palette gives one colour to every series in a
  pie, a stat and a bar gauge (25-slice pie all cyan; bar gauge 2 distinct colours in 50 swatches) and a stable colour
  per name on a time series (17 distinct for 25 names); an instant query with *All values* colours equal counts alike
  (`team-a` and `team-b`, two pods each); a caption's marker on the text's line renders raw markdown; a bar gauge on a
  range query does not sort. Every one of those is a panel on `tut-2` or `tut-3` now, with the caption saying so.
- The screenshots are full-page captures; a horizontal band across the middle of some is the capture's stitch, not
  the dashboard.
