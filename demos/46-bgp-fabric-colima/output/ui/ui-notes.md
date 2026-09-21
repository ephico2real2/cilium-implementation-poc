# demo 46-colima dashboard — the signal on the page

Captured against the live Colima lab on `127.0.0.1:8098` by
`tests/walk46-colima-signal.mjs` (Playwright `1.63.0` from `.tmp/pw`, the same
pin as `.github/actions/browser-walk/action.yml`, Chromium at
`deviceScaleFactor: 2`). `document.body.dataset.ready` was `"1"` and the
WebSocket label was `live` on every shot.

The Desktop lab's own capture is at `demos/46-bgp-fabric/output/ui/ui-notes.md`
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
