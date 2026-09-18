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

Where this tutorial says *measured*, the fact was read from this Grafana's DOM or API on 2026-09-17 (the commands are
in `check.sh`, `capture.js` and the Evidence section); everything else is Grafana's documented behaviour, linked at the
end of each section.

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

Seven questions, seven visualizations, all from one Linux node's exporter (the expressions in this README are
abbreviated; the exact PromQL with its `$cluster`/`$node` filters is in `build.py`). Read the caption under each panel, then
change the `node` variable and watch which panels change shape and which only change numbers.

| The question | The chart | The panel | Why this one |
|---|---|---|---|
| What is it **now**? | **Stat** | CPU busy % per node, sparkline | one number per series, coloured by threshold; the sparkline is the trend without a second panel |
| How far from the **limit**? | **Gauge** | memory used % | a gauge needs a real ceiling (100 % of RAM); without one it is decoration |
| What happened, and **when**? | **Time series** | load average per node | the default for anything with a time axis; one line per series, named in the legend |
| What **share** of a whole? | **Pie** | CPU time by mode on `$node` | the slices add up to 100 % of the node's CPU time (all cores); eight modes, four of them visible — a pie tolerates a long tail of near-zero slices, not eight that matter |
| Who is **biggest**? | **Bar gauge** | network receive by interface, top 5 | a ranking is a comparison between categories: bars sorted, the number beside each name, one colour |
| Which **state**, for how long? | **State timeline** | node_exporter `up` | discrete states over time; the colour band's length is the duration |
| Every **row**? | **Table** | `node_uname_info` | when the reader needs the facts, not a shape — hide the columns that carry nothing |

Grafana's own wording: a pie is for "data that adds up to a total and you want to show the proportion of each
value compared to other slices, as well as to the whole"; bar charts are what it recommends for categorical
comparisons; a gauge shows "how far a single metric is from a threshold"; a stat is "for big stats and optional
sparkline". Hold every panel you build to that table.

**Try it.** Edit the pie (panel menu → Edit) and change *Value options → Show* from *Calculate* to *All values*: the
legend fills with the same name repeated — `idle 4 %, idle 4 %, …`, one slice per sample, because a range query has
many values per series (measured: 25 rows for one series over 15 minutes). Put it back. Then edit the bar gauge
and switch its query from *Instant* to *Range*: on this Grafana the bars stopped sorting — a range query arrives as one
frame per series and the `sortBy` transformation orders rows inside a frame (measured on this panel, 2026-09-17; the
Evidence section has the numbers).

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
*Calculate*: last, mean, max…); one that draws rows takes the table as it is (*All values*). Two lessons on this
dashboard. First, four panels show the same `count by (namespace) (kube_pod_info)` (five namespaces) reduced
differently, and the two pies that look identical are not:

- *Range + last value* and *Range + mean*: the same series, two reducers. While nothing changes in the window the two
  agree (`35, 5, 4, 2, 2` on both); the moment a pod comes or goes they part — the first capture showed the mean at
  `2.02` where the last value said `2`. The reducer is part of the question — say which one you show.
- *Instant + All values* and *Range + Calculate*: the same five counts. The first colours **equal counts alike**:
  `team-a` and `team-b` have two pods each and share a colour, because the instant query is one table and Grafana
  colours its rows by value. The second is one series per namespace, one colour each. Prefer the second shape for pies
  and legends. (The observer dashboard had the first shape until today — §6.)

Second, a different query — `rate()` of a network counter — with two windows: `$__rate_interval` and a fixed `[1m]`.
Zoom both to seven days. The panel's step grows to minutes, and a fixed one-minute window then covers only a slice of
each step: the line turns spiky and gappy. `$__rate_interval` is defined to cover the step (at least four scrape
intervals, and never shorter than step + scrape), so the line stays continuous at every zoom.

**Try it.** Scale a deployment so two namespaces have the same pod count; watch the left pie merge their colours and
the right one keep them apart. Then zoom the two rate panels to seven days and compare.

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
| a **category's identity** | fixed colour per name — `overrides` with a `byName` (or `byRegexp`) matcher | *Pod phases*: Running green, Pending yellow, Failed red, Succeeded grey, Unknown purple | the same meaning has the same colour on every dashboard, every load; never rely on palette position for a category people recognise |
| a **quantity on a scale** | thresholds, or a continuous scheme | *Deployments available/desired*: red → orange at 90 % → green at 100 %; *Restarts* table with cell background | thresholds are for numbers; a threshold on a category is noise |
| **nothing** (the shape already carries the value) | one fixed colour | *Pods per namespace* bar gauge | a colour per namespace would change every time a namespace appears and mean nothing |

**When new items appear.** Two palette modes for open-ended categories, and what each does was **measured** on this
Grafana (13.2.1) rather than read from the option's name:

| Visualization | `palette-classic` (by index) | `palette-classic-by-name` |
|---|---|---|
| time series | every line its own colour — until a series is added and the colours shift | **works**: a name keeps its colour as others come and go (17 distinct colours for 25 namespaces — the palette has about twenty, so unrelated names can collide) |
| pie, bar gauge, stat | one colour per series by order — the same shifting | **one colour for every series** (a 25-slice pie all cyan; a bar gauge with 2 distinct colours in 50 swatches) — [grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275), closed as not planned |

So: for a **time series** whose series come and go, by-name is the right default; on a **pie, stat or bar gauge** the
option exists but mis-colours (one colour for every series) — fix the colour per name with an override for categories
that have a meaning (verdicts, phases, drop reasons), and for open-ended rankings use one colour and let the length
speak (§1). (The "2 distinct colours in 50 swatches" of the bar gauge are the one series colour and the bars' unfilled
track — one colour for the data.) The dashboard shows
all four cases side by side on five namespaces.

**Try it.** Create a namespace named `aaa-test` with one pod and reload: the by-index pie and time series recolour;
the by-name time series adds one line and keeps the others' colours; the by-name pie stays one colour.

**Learn more** — docs: [Configure standard options — color scheme](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-standard-options/),
[Configure thresholds](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-thresholds/),
[Configure value mappings](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-value-mappings/),
[Configure field overrides](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-overrides/);
the by-name palette's history: [grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275).

## 4. Units, legends, captions — the words — `tut-4-meaning`

The same time series three times: raw (the one panel in this demo without a description, on purpose); with a unit and
a named legend; with a title that says what and in which unit,
a hover description that says where the data comes from, and a caption that says what "normal" looks like. The third
is the only one a stranger can read. Meaning is added in words, not colours; the checklist at the bottom of the
dashboard is the one this lab applies to every panel it ships:

- the title says **what** and the **unit**;
- the unit is set (`Bps`, `percent`, `short`) — Grafana scales it (`1.2 MB/s`) and the reader stops counting zeros;
- the legend names the series (`{{instance}}`, not `{__name__=…}`), and shows the calculation that matters (mean, max);
- the description says the **source** and the **window** (node_exporter, `rate` over 5 m);
- a caption under the panel says what normal looks like and **what an empty panel means**;
- colours mean one thing (§3).

**Try it.** Edit the middle panel and set the unit to *bytes(IEC)* instead of *bytes/sec(IEC)*: the number is the
same, the meaning is wrong, and only the unit told you. Put it back.

The captions are transparent **text panels** in markdown, two or three grid rows high, under each panel — a `description` only
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
   `capture.js` reads the rendered captions back and fails if any still shows `**` or a backtick (the marker bug's two
   symptoms) or the state timeline's legend lacks `UP`. A dashboard that says "No data" in a
   screenshot nobody looked at is a dashboard that lies.
5. **Version it.** Dashboards live next to the code that produces the data, in the same pull request.

**Try it.** Pick one cluster in the `cluster` dropdown — one repeated row disappears; pick a namespace — the *Pods*
stat changes and *Nodes* does not, because only one query reads `$namespace`. Then run `build.py` after adding a panel
to `tut-5` and `provision.sh`: the dashboard updates without a click in Grafana.

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

Then open the observer dashboard (`/d/hubble-observer-23862`). It is the same grammar on **Loki flow logs**: a stat
for the count, small pies with fixed colours per meaning, bar gauges for the two rankings, a time series for the rate,
a caption under each. Before today it had §2's fault — three pies on an instant query coloured equal counts alike —
and no captions, so a reader could not tell that every panel counts drops. **Try it:** find the panel whose caption
says what makes it empty, and make it fill (demo 31's `pos` pod and one `wget`). The research behind the redesign,
field by field from Cilium's `flow.proto`, is
[`docs/OBSERVER-DASHBOARD-PANELS.md`](../../docs/OBSERVER-DASHBOARD-PANELS.md); the L7 dashboard's own blind spot and
its app-keyed fix is [`docs/HUBBLE-L7-LABELS.md`](../../docs/HUBBLE-L7-LABELS.md).

**Learn more** — [Cilium: running Prometheus and Grafana](https://docs.cilium.io/en/stable/observability/grafana/),
[Hubble metrics reference](https://docs.cilium.io/en/stable/observability/metrics/); demo 16 (the stack), demo 25
(the observer), demo 26 (the verdict dashboards).

## 7. What to take away

- **The question decides the chart.** Now → stat; limit → gauge; when → time series; share of a whole with few slices
  that matter → pie; ranking → sorted bars; state → state timeline; rows → table.
- **The reduction is part of the question.** Last, mean or max; instant table or range series — say which.
- **Colour carries one thing**: identity (fixed per name), quantity (thresholds), or nothing (one colour). New items
  get stable colours by name on a time series; on a pie, stat or bar gauge by-name mis-colours — write the override.
- **Meaning is words**: unit, legend, description, caption. A panel that needs a hover to be understood is unfinished.
- **Grow with variables and generators**, prove with the API, version with the code.

## Evidence (2026-09-17, poc1 + poc2, Grafana 13.2.1)

- `provision.sh`: six ConfigMaps, all six uids answered by the API within the sidecar's poll — `tut-1-question` 15
  panels, `tut-2-time` 12, `tut-3-colour` 16, `tut-4-meaning` 7, `tut-5-grow` 8, `tut-6-cilium` 7: 65 panels = 30 with
  a query + 31 captions + 4 plain text panels (*How to read this page*, *The checklist*, *From here*, `tut-5`'s opener).
- `check.sh`: **30 panels, every one with data, 0 `NO DATA`** — e.g. CPU busy 4 series (two nodes × two clusters),
  CPU by mode 8 (eight modes; four visible in the pie), network top 5 → 5, the five filtered namespaces → 5, pod
  phases 5 (all five coloured), flows/s by verdict 3 (of the five verdicts given a colour, three occur on this lab),
  drops by reason 3.
- `capture.js`: six screenshots under [`output/screenshots/`](output/screenshots/), 31 captions read back with no `**`
  and no backtick left (the marker bug's symptoms), the state timeline's legend says `UP`; exit 0.
- Measured while building, and now part of the lessons (two different mechanisms, kept apart): **by-name palette** —
  one colour for every series in a pie, a stat and a bar gauge (25-slice pie all cyan; the bar gauge's 2 distinct
  colours in 50 swatches are the series colour and the unfilled track), a stable colour per name on a time series (17
  distinct for 25 names); **instant + All values** — equal counts coloured alike (`team-a` and `team-b`, two pods each).
  Also: a caption's marker on the text's line renders raw markdown; on this panel a bar gauge on a range query did not
  sort. Each is a panel on `tut-2` or `tut-3`, with the caption saying so.
- The screenshots are full-page captures; a horizontal band across the middle of some is the capture's stitch, not
  the dashboard.
