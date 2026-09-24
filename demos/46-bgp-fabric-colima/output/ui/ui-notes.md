# demo 46-colima dashboard — the signal on the page

Captured against the live Colima lab on `127.0.0.1:8098` by
`tests/walk46-colima-signal.mjs` (Playwright `1.63.0` from `.tmp/pw`, the same
pin as `.github/actions/browser-walk/action.yml`, Chromium at
`deviceScaleFactor: 2`). `document.body.dataset.ready` was `"1"` and the
WebSocket label was `live` on every shot.

The Desktop lab's own capture is at `demos/55-bgp-fabric-desktop/output/ui/ui-notes.md`
and covers the 375 px work. This one covers what the signal API put on the page.

## What the page reads

| Mark | Field | Measured here |
|---|---|---|
| teal border | `router.dynamicPeers > 0` | leaf1 and leaf2 accepting=1, spine and edge accepting=0 |
| node pulse | `session.dRcvd`/`dSent` this tick | fires on a measured delta, not on a frame without one |
| dotted, faded node | `hasDelta`/`hasTimers` both false | the two kube-vip nodes, which are peers and not polled routers |
| `age` in the header | `snapshot.ageMsec`, stamped when served | `live` under 4 s, `stale 42s` above 10 s |
| the strip beside the RIB | the selected router's sessions | `cluster peers 2 · accepting traffic · quietest 2000ms · flaps since boot 9` |

## Recorded

```text
1200  nodes=6 edges=7 ws=live overflow=0
      age="age 0s"
      strip="sessions 3 cluster peers 2 state accepting traffic peers keepalives on time
             quietest 2000ms flaps since boot 9"
      node edge             accepting=0 signal=ok      known=1
      node leaf1            accepting=1 signal=ok      known=1
      node leaf2            accepting=1 signal=ok      known=1
      node spine            accepting=0 signal=ok      known=1
      node 172.20.0.3       accepting=0 signal=unknown known=0
      node 172.20.0.4       accepting=0 signal=unknown known=0
      side rows=402.062px 6px 285.156px
      rib top=107 h=402 | splitter top=509 h=6 | events top=515 h=285
      splitter: graph pane 780px -> 480px
      after resize: canvas=480px nodes inside=6/6
      keyboard: aria-valuenow=44
heartbeat: socket silenced, idle=false | after a frame with no delta beating=false
           | after a measured delta beating=true
stale: age.class="stale" text="age 42s · stale 42s" body.stale-data=true
375   innerWidth=375 scrollWidth=375 splitter=none
```

## Shots

| File | What it shows |
|---|---|
| `1200-signal.png` | the four routers with leaf1 and leaf2 marked accepting, and the strip filled |
| `1200-split-40.png` | the graph pane dragged to 40%, all six nodes still inside the canvas |
| `1200-stale.png` | a 42-second-old snapshot: the graph faded and the header saying so |
| `375-signal.png` | the same page at a real 375 px, no overflow, splitters hidden |

## Activity: Events, and Traffic

Filtering Events by `router` returned a blank pane. That was correct — a router
event is a router going unreachable or coming back, and none had — but the page
said nothing, and the option was read as "traffic between the routers".

Measured on the ring at the time: 55 events, 38 `route` and 17 `session`, and
**zero** `router`.

Three things changed:

| Before | Now |
|---|---|
| a blank list | the reason, and which of the three cases it is |
| `session` / `route` / `router` | `session up/down` / `route added/withdrawn` / `router reachable/unreachable` |
| no view of ongoing traffic | a Traffic view, one row per link, from the same measurements the heartbeat uses |

Traffic is one row per link rather than per session, so a fabric link is a
single line carrying both directions. The far end of a cluster link reads
**not polled** — the node is a BGP peer, not an agent we can read — which is a
different statement from zero.

```text
7 links · 6 carried a message on the last poll
edge  ⇄ spine          2 ⇄ 2 msg        heard 1.0s
      fabric link · 4 in / 5 out prefixes · 2 flaps since boot
spine ⇄ leaf2          2 ⇄ 2 msg        heard 1.0s
      fabric link · 2 in / 6 out prefixes · 2 flaps since boot
leaf1 ⇄ 172.20.0.3     2 ⇄ not polled   heard 1.0s
      cluster node peering in · 1 in / 0 out prefixes
```

## What each router is for, and arranging the picture

Two gaps the operator named: the topology said `edge`, `spine`, `leaf1`,
`leaf2` without saying what those mean, and the nodes could not be moved.

The role text is **configuration**, not inference. A leaf with no cluster
attached right now looks exactly like a spine, so the fabric says it in
`DASHBOARD_ROLES` and the dashboard stays generic. Read off the `frr.conf`
files:

| Router | Config it comes from |
|---|---|
| edge | one fabric neighbour; originates `10.200.100.0/24` |
| spine | three fabric neighbours; no listen range |
| leaf1 / leaf2 | one fabric neighbour plus `bgp listen range 172.20.0.0/17` |

The legend fills the dead strip under the topology, marks the routers that are
currently accepting a cluster, and describes the dashed ellipses once rather
than per node.

Selection is Cytoscape's own: drag the background to box-select, and dragging
one selected node moves the whole selection. What the page adds is memory —
`renderGraph` rebuilds the elements on every state change, so without it the
next tick threw the arrangement away and snapped everything back to the
layout. Hand-placed nodes are also exempted from the narrow-width pull-back,
which exists to rescue the automatic layout, not to overrule a decision.

```text
roles: 5 entries, inside the graph pane=true
      edge  AS 65000   accept=false  the border. It faces the WAN 10.200.100.0/24 …
      spine AS 65100   accept=false  transit only. Every leaf reaches the edge …
      leaf1 AS 65101   accept=true   where a cluster attaches. `bgp listen range …
      leaf2 AS 65102   accept=true   where a cluster attaches. The second one …
      dynamic neighbour              2 peers that arrived through a leaf's listen range …
selection: 6 nodes selected, 6 recorded as placed
      arrangement survived a re-render: true
      after reset: placed=0 stored={}
```

## The peers were missing, and the states had no colour

Two things the rebuild had quietly dropped, both of which the page was already
carrying the data for.

**No neighbours table.** The RIB answers "what do I know"; nothing answered
"who told me". `pfxRcd`, `pfxSnt`, `peerAsn`, `state`, `uptime` and `hostname`
were all in `/api/state` and none of them were rendered. There is a NEIGHBOURS
table now, above the BGP table, with the peer (and its hostname on a muted
second line), the AS, the state, prefixes each way and the uptime.

**States were coloured by KIND, not by state.** The event dot said `session`,
`route` or `router`; nothing said Established or Idle. `ui.stateClass` now maps
a state to a colour wherever one is shown — events, neighbours, the RIB — and
it matches on a PREFIX: `Idle (Admin)` is an administrative shutdown and has to
read as down, not fall through to the unknown colour. The exact-match version
of that is a filed bug in the dashboard this one learned from, and a test kills
the mutant.

The RIB also gained the **LP** and **MED** columns. `locPrf` and `metric` were
in the model, `omitempty`, and never shown; blank means FRR sent none, which is
not the same as nought.

### Three layout defects on the way there, each found by looking

The walk's overflow assertion caught the first; it could not see the other two,
so it gained a legibility check — header labels must not overlap the next
column, and a cell's own text must not wrap past three lines.

```text
1. seven RIB columns + a six-column table   page overflowed by 41px at 1200
2. table-layout: fixed, six equal columns   the head rendered "peAS state pfx
                                            rpdx suptime" and the address drew
                                            over the AS column
3. width: max-content on the table          the pane's floor became the table's
                                            width — the page went 128px wide
```

The third is the interesting one: a flex or grid item's floor is its content
unless it is given `min-width: 0`, so the table stopped scrolling inside its
wrap and widened the page instead. The tables size to their content and the
wrap scrolls; at phone width a media rule shares the columns instead, scoped
`#rib-pane .neighbours` because the sizing rule is declared later in the file
and would otherwise win on source order.

My own first legibility assertion was wrong too: it measured cell height, and a
table cell stretches to its row, so one wrapping cell reported every cell in
the row as wrapped. It counts the rects of the cell's own text node now.

## One meaning per channel

Selection was invisible on the routers while the dashed ellipses showed it
clearly. Two causes, both measured:

- `node.picked` came **after** `node:selected` in the style array, and
  Cytoscape takes the last matching declaration, so the router being read never
  looked selected at all.
- `overlay-padding` is an absolute number. The same 5 px halo is a thin rim on
  a 90 px router and a broad ring on a small ellipse.

The fix was to stop overloading two channels. The node border already carried
three meanings and the overlay carried two:

| Channel | Meaning |
|---|---|
| edge colour | session state — Established, transitional, down, stale |
| node border | accepting a cluster (teal), keepalive late/critical, the picked router (blue) |
| node **outline** | selected — violet, `node:selected` placed last so nothing overrides it |
| node **underlay** | the heartbeat pulse |
| node overlay | hover, and the picked router's wash |

An outline follows the node's own shape and size, so it reads the same on a
wide router and a small ellipse. The heartbeat moved to the underlay because
animating `overlay-opacity` to 0 left the picked router without its wash after
the first beat.

```text
selection outline: edge=4px leaf1=4px (picked) leaf2=4px spine=4px
                   172.20.0.3=4px 172.20.0.4=4px
unselected:        edge=0px leaf1=0px leaf2=0px spine=0px
                   172.20.0.3=0px 172.20.0.4=0px
```

The legend resizes like the other panes — a third splitter, the same
persistence, and Cytoscape re-fits into whatever is left:

```text
legend height: 213px → 368px (45%) → 98px (12%)
graph got the rest: 714px, cytoscape canvas 714px
```

## What the review found that the walk could not

The walk reads `textContent`. It cannot see colour or geometry, and three
defects lived in exactly that blind spot.

**The escaped message was fixed at the symptom, not the cause.** `.empty` is
the graph's overlay — `position: absolute; inset: 0` — and giving the Events
message its own `.pane-empty` left the *other* user of the class, the signal
strip, still resolving against the viewport. Measured at
`?router=<a name the fabric does not have>`:

```text
before  position=absolute  box=[0,0,1200,796]   rib-pane=[787,107,1200,509]
after   position=static    box=[797,139,1190,165]
```

The class is now `#graph-empty`, keyed by id so it cannot be reused by
accident.

**The Traffic view painted nothing.** `.moving`, `.idle`, `.unpolled` and the
coloured `heard` cell had no CSS at all — the rules were written for the table
this list replaced and went out with it:

```text
before  moving=rgb(28,25,22)  idle=rgb(28,25,22)   <- identical
        heard-ok=rgb(92,86,78) heard-critical=rgb(92,86,78)   <- identical
after   moving=rgb(28,25,22)  idle=rgb(92,86,78)
        heard-ok=rgb(92,86,78) heard-critical=rgb(180,35,24)
```

A session two thirds through its hold time was painted like a healthy one.

**The caption invented a measurement.** It counted `messages > 0` and reported
`7 links · 0 carried a message on the last poll` while every cell read
`unmeasured`. `known` was computed for exactly this and never read. It now says
`nothing measured on the last poll`, or `N of M measured` when only some links
were read.

Two smaller ones: a fabric link's prefix and flap counts belong to **one** end
and the row never said whose (`spine: 2 in / 6 out prefixes` now), and a link
that is **down** rendered as `unmeasured`, indistinguishable from one we simply
failed to read — it renders `idle` in the critical colour now.

And two of the walk's own assertions did not assert. The liveness check
captured a value, discarded it with `void before`, and tested only that the
list was non-empty — which passes identically with the socket closed. It
compares node identity now, since `renderTraffic` rebuilds the `<ul>`. The
topology counts were hard-coded to this lab's 7/3/4; they are read from
`/api/state`, so the assertion tests the invariant that matters — the view
drops no edge — with a floor so it cannot pass against a lab that is down.

## A placement could lose a node with nothing to say so

The arrangement is remembered per browser, and the pull-back that keeps nodes
inside a narrow pane skipped any node the reader had placed — on the reasoning
that a rescue must not overrule a decision. It overruled nothing; it simply let
the node leave the canvas. The ordinary case is the bad one: arrange on a wide
window, reopen on a narrower one.

```text
before   arranged @1400 → opened @1200   4/6 on canvas, off=[leaf1 spine], 0 JS errors
         six placements at 9000,9000     0/6 on canvas — a blank graph, no error
         {"leaf1":{"x":"abc"}}           node painted at ("abc", 0)
after    every case                      6/6 on canvas
```

Three changes. A placed node is now rescued only when **none** of it is on the
canvas, so a visible placement is still never moved and the recorded position
is left untouched — the arrangement returns at the width that made it. What
comes out of `localStorage` is validated to finite numbers, because anything on
the origin can write it and Cytoscape does not check a position. And the
counter reports only placements that are actually in the topology, so two ghost
ids no longer claim "2 placed by hand" over a picture with nothing moved, while
Reset stays enabled so the record can still be cleared.

## Three defects this walk found that review had not

1. **The pulse fired on a frame that measured nothing.** The signal frame is
   authoritative for a tick, but sessions missing from one kept the previous
   tick's deltas, so a vanished peer's last delta would have driven the
   heartbeat for ever. `applySignal` now clears them.
2. **A grid track slid up under a `display:none` sibling.** `.tabs` is hidden
   above 700 px, so it leaves the grid entirely and auto-placement moved every
   child up one track: the splitter took the RIB's 58% row as a 402 px grey
   void and the Events pane was squeezed into the 6 px one. Tracks are assigned
   by name now, and the walk asserts the order and the sizes.
3. **Two assertions were testing the clock.** A live frame arrives every 2 s and
   a pulse leaves its flag set for 580 ms, so both injection cases passed or
   failed by luck. They silence the WebSocket first; the walk then passed three
   times in a row.
4. **The empty message escaped its pane.** It reused `.empty`, which is
   `position: absolute; inset: 0` for centring over the graph, so inside the
   activity pane it resolved against the wrong ancestor and painted the
   sentence across the topology and the RIB. The walk now asserts the message's
   box is inside its pane.
5. **The first Traffic layout was a five-column fixed table.** In a 414 px pane
   it wrapped the link name over four lines and fitted three rows on screen. It
   is a list now, 43 px a row, and the walk fails if a row grows past 46 px.
