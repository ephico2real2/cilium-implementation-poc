# Review — the blog's BGP dashboard source (fork `ephico2real2/bgp-lab-with-dashboard`)

**Source:** [vadaszgergo/bgp-lab-with-dashboard](https://github.com/vadaszgergo/bgp-lab-with-dashboard) at `aaaaac1`
(the blog [Make BGP visible: a live topology dashboard with Containerlab](https://gergovadasz.hu/make-bgp-visible-a-live-topology-dashboard-with-containerlab/)),
forked on 2026-09-20 to [ephico2real2/bgp-lab-with-dashboard](https://github.com/ephico2real2/bgp-lab-with-dashboard)
on the operator's instruction ("fork it and let us review it for enhancement and then create issues for it the fork").
The source has **no licence** (GitHub `license: null`, measured), so the fork is for study and issues; our own
dashboard (demo 46 phase 2, enhancement 006 D8/D9) is a clean-room implementation of the idea.

**What was read:** every file — `dashboard/app/{main.py,poller.py}`, `static/{index.html,dashboard.js,styles.css}`,
`Dockerfile`, `requirements.txt`, `simple.clab.yml`, the four `frr.conf`, both READMEs (717 lines of app source).

**What was measured to ground the findings (2026-09-20, FRR 10.7.1 on the demo 46 fabric unless said otherwise):**

| Claim | Measurement |
|---|---|
| The state-unchanged short-circuit (`poller.py:67`) never fires | two `show ip bgp summary json` 2 s apart differ per peer in `msgRcvd`, `msgSent`, `peerUptime`, `peerUptimeMsec` |
| The detail payload is the heavy one | spine, 7 prefixes: `show ip bgp detail json` 4865 B, `show ip bgp json` 3174 B |
| The two JSON shapes the parser handles | `show ip bgp json`: `bestpath: true`, `path` string; `detail`: `bestpath: {overall, selectionReason}`, `aspath.string` |
| A hung `vtysh` blocks the poll forever | throwaway FRR 10.7.1 container, `kill -STOP bgpd`: `docker exec … vtysh -c 'show ip bgp summary json'` not returned after 20 s |
| The image is single-arch | `docker manifest inspect -v vadaszgergo/bgp-dashboard:0.1.0` → `linux/amd64` only |
| Newest FRR tag | quay.io tags: `10.7.1` (2026-08-26); the source pins `10.5.3` |
| Management over the data plane goes blind | demo 46 first dashboard run, 13:32Z: spine and both leaves unreachable 13:32:16.7→:19.7 during `clear bgp *` on the spine |

## The issues filed on the fork

| # | Finding | Labels |
|---|---|---|
| [1](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/1) | Node inventory and ASN come from the topology file and a regex — read them from BGP itself | enhancement |
| [2](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/2) | Graph keys nodes by ASN: peers outside the file are invisible and two routers in one AS collapse | bug, enhancement |
| [3](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/3) | Edge state is 'whichever side was iterated last' — make it the worse of the two | bug |
| [4](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/4) | A peer that disappears produces no event and its edge stays green | bug |
| [5](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/5) | Best-path events only for prefixes that already existed — no added/withdrawn events | enhancement |
| [6](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/6) | Events: local-time HH:MM:SS, no history, no REST endpoint | enhancement |
| [7](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/7) | Cytoscape is loaded from unpkg at runtime — vendor it | enhancement |
| [8](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/8) | Docker exec calls have no timeout; one hung router stalls every poll | bug |
| [9](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/9) | Published image is linux/amd64 only | enhancement |
| [10](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/10) | Unescaped router data rendered with innerHTML | bug |
| [11](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/11) | No tests; no fixtures of FRR's JSON | enhancement |
| [12](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/12) | Docs: 'Extending' says cose re-runs on every diff — the code never re-lays out | documentation |
| [13](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/13) | FRR image pinned to 10.5.3; `no bgp ebgp-requires-policy` on every router | documentation, enhancement |
| [14](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/14) | Management over the data plane: with the socket gone, keep the dashboard out of band | enhancement |
| [15](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/15) | No licence file | documentation |
| [16](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/16) | Dashboard holds the host's Docker socket — replace with a read-only, show-only agent on a management network | enhancement, security |
| [17](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/17) | The state-unchanged short-circuit never fires: full state is broadcast to every client every poll | bug, performance |
| [18](https://github.com/ephico2real2/bgp-lab-with-dashboard/issues/18) | Dashboard listens on 0.0.0.0 and is published on all host interfaces | security |

## What the source does well (kept in our design)

- FRR's JSON is the data source; the diff is the event log — no SNMP, no screen-scraping.
- Sessions drawn as coloured edges, an Events pane, a per-router RIB pane: the three views a BGP learner needs.
- Both `bestpath` shapes handled (`poller.py:157-158`); warnings before the JSON trimmed to the first `{`
  (`poller.py:98-100`).
- `preset`-style stability after the first layout: `updateGraph` patches data and never re-lays out
  (`dashboard.js:206-228`), so the reader's mental map holds while sessions flap.

## Not filed

- Style/format nits (no linter config, `print` for logging). Not worth an issue on a lab.
- `docker.from_env()` + `containers.get` per node per poll (three Docker API round trips per router every 2 s):
  fine at four routers; folded into #8's per-router scheduling.
