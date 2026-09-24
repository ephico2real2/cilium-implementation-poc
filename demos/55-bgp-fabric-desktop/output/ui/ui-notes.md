# dashboard UI — measured evidence (Playwright viewport)

Throwaway `bgp-dashboard:ui` on `bgp-fabric_mgmt` (`ui-probe` `:8090`,
`ui-probe-dead` `:8091`). The live fabric dashboard on `127.0.0.1:8088`
was not restarted, rebuilt, or pointed at. Playwright `1.63.0` from
`.tmp/pw` (same pin as `.github/actions/browser-walk/action.yml`),
Chromium `newContext({viewport, deviceScaleFactor})`.
`document.body.dataset.ready` was `"1"` and `wslabel` was `live` on
every shot except the held-open WebSocket gap.

## Viewport (the previous 375 numbers were invalid)

Chrome `--dump-dom --window-size=375,700` reported pane **500×294**
(same painted total as 1200: 20,818). Playwright at
`{width:375,height:700,deviceScaleFactor:2}` reports
`window.innerWidth=375`, graph pane **375×336**.

| asked | tool | innerWidth | scrollWidth | pane | leaf2 box | page overflow |
|---|---|---|---|---|---|---|
| 375×700 | Chrome dump-dom (previous) | (clamped) | — | 500×294 | n/a (wrong pane) | PNG cropped the 500 px layout |
| 375×700 | Playwright, before CSS fix | 375 | 375 (Δ 0) | 375×336 | 236.5–303.5 | table +23.7 px (`getBoundingClientRect`) |
| 375×700 | Playwright, after | 375 | 375 (Δ 0) | 375×336 | 236.5–303.5 | none |
| 1200×700 | Playwright | 1200 | 1200 (Δ 0) | 780×618 | 574.9–641.9 | none |

After `ready=1`, `document.documentElement.scrollWidth <= innerWidth`.
Elements with `getBoundingClientRect().right > innerWidth + 0.5`:
**none** (was the RIB `table` at right 398.7 / +23.7 px before
`table-layout: fixed`). Cytoscape `renderedBoundingBox()`: 6/6 nodes
inside the canvas, **0** overlaps, at both 375 and 1200.

## What changed

- Lede: `overflow-wrap: anywhere` so the intro cannot run off the pane.
- Tabs: `flex-wrap: wrap` + `min-width: 0` so RIB / Events stay fully
  visible (they already fitted at a real 375; the old PNG clipped
  `Eve` because it was a 500 px layout cropped to 375).
- RIB table: `table-layout: fixed; width: 100%` under 700 px — cells
  wrap inside the pane instead of extending 23.7 px past it.
- Events: `flex-wrap: wrap` at every width; `.change` is
  `flex: 1 1 10em` so `reachable→unreachable` is not clipped to `ur`.
- Graph pane: `width: 100%; min-width: 0`. Layout already used the
  real pane once Playwright gave it 375 px.

Hooks added (smallest, for Playwright): `window.__cy`,
`window.__ws`, `window.__ingestEvent`, `window.__gapFill`
(`{since, count}` after `/api/events?since=`),
`window.__holdReconnect` (skip the reconnect timer),
`window.__connect`.

## Shots

### `375-graph.png` (750×1400 = 375×700 @ 2×, `?router=spine`)

innerWidth 375, pane 375×336, scrollΔ 0. Lede wraps in full
(`…the management-LAN agents report.`). Tabs `RIB` 187.5 / `Events`
187.5. leaf2 236.5–303.5 (71.5 px inset). Two externals on one row,
no overlap. WebSocket `live`. Header `routers 4/4`,
`fabric sessions 6/6 · server sessions 4/4`.

### `375-rib.png` (same viewport, `?tab=rib`)

Default tab is RIB — same chrome as `375-graph.png`. Spine RIB with
`*`; prefix / from wrap inside the table (no page overflow).

### `375-events.png` (same viewport, `?tab=events`)

Events tab selected (full word). Toolbar wraps. Rows show relative
time (`12s ago` on this frame). leaf2 still 236.5–303.5.

### `1200-steady.png` (1200×700, `?router=spine`)

Pane 780×618, leaf2 574.9–641.9, 6/6 inside, 0 overlaps. Header
4/4 · 6/6 · 4/4, WebSocket `live`. Legend on one row. ECMP grouped.

### `1200-selected.png` (1200×700, `?router=spine&hover=edge|spine`)

Hover card: `edge 10.200.1.18 Established … rcd 5 snt 5 · spine
10.200.1.19 Established … rcd 2 snt 7`.

### `1200-focus.png` / `1200-focus-enter.png`

Tab until `#node-keys [data-node=edge]` focused; Cytoscape
`.focused` on edge. Enter → RIB why `edge selected from the keyboard`,
`.picked` = edge.

### `1200-paused.png`

Pause, then `window.__ingestEvent` × 3 (fabric was quiet). Label
`paused, 3 new`, button `Resume`.

### `1200-ws-gap.png` then `1200-ws-catchup.png` / `1200-unreachable.png`

`ui-probe-dead` with `ui-leaf2-gw` socat. `__holdReconnect=true` +
`__ws.close()`, then `docker stop ui-leaf2-gw`.

- gap: `WebSocket retrying (1)`, header still `routers 4/4`,
  events 38, `__gapFill` `{since:38,count:0}` — page has not moved.
- catchup: `__holdReconnect=false`, `__connect()`. `live`,
  events 39, `__gapFill` `{since:38,count:1}` — one ring event
  (`leaf2 reachable→unreachable`). Header
  `routers 3/4 · cannot reach leaf2 — last seen 6s ago`. RIB wash +
  last-known sentence. leaf2 edges dashed. `1200-unreachable.png` is
  the same frame.

## Contrast (unchanged; WCAG hex vs token surfaces)

`--trans` on light `#a35f00`. `bgpUI.contrastRatio`: all four state
colours ≥ 3:1 on light `--bg` / `--panel` and dark `--bg` / `--panel`.
`--trans` on light `--bg` is 4.44 (swatch, not small text).

## Unit tests

`bash tests/dashboard-ui-unit.sh`: `node --check` on `ui.js`,
`app.js`, `ui.test.js`; `node --test ui.test.js` — 9 tests.
`go vet ./...` and `go test ./...` in `dashboard/` (includes
`TestLastSeenFrozenWhenUnreachable`).

## Not verified

- Dark-mode appearance (tokens + contrast only; no dark-scheme PNG).
- The six-external 1200 collision on a live graph (only two
  externals were present). Covered by `node --test`.
- Pause counter from a *natural* fabric event (shot used
  `__ingestEvent` × 3 because the Established fabric emitted nothing
  during the wait). The label and Resume control are real.
- Keyboard focus ring on the clipped `#node-keys` button itself
  (1×1). The visible ring is the Cytoscape `.focused` overlay.
