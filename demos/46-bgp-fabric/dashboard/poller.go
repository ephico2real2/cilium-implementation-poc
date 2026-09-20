package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const holdDown = 30 * time.Second

type heldSession struct {
	Session
	goneAt time.Time
}

type poller struct {
	routers []RouterCfg
	asNames map[int]string
	poll    time.Duration
	client  *http.Client

	mu     sync.Mutex
	prev   Snapshot
	ready  bool
	held   map[string]heldSession // router|peer
	lastOK map[string]routerView  // last successful poll per router
}

type routerView struct {
	asn      int
	routerID string
	sessions []Session
	routes   []Route
}

func newPoller(routers []RouterCfg, asNames map[int]string, poll time.Duration) *poller {
	return &poller{
		routers: routers,
		asNames: asNames,
		poll:    poll,
		client:  &http.Client{Timeout: 3 * time.Second},
		held:    map[string]heldSession{},
		lastOK:  map[string]routerView{},
	}
}

func (p *poller) tick(now time.Time) (Snapshot, []Event, bool) {
	type result struct {
		name    string
		url     string
		ok      bool
		summary frrSummary
		ipv4    frrIPv4
	}
	ch := make(chan result, len(p.routers))
	var wg sync.WaitGroup
	for _, r := range p.routers {
		wg.Add(1)
		go func(r RouterCfg) {
			defer wg.Done()
			res := result{name: r.Name, url: r.URL}
			sumRaw, err := p.get(r.URL + "/show/bgp-summary")
			if err != nil {
				ch <- res
				return
			}
			sum, err := decodeSummary(sumRaw)
			if err != nil {
				ch <- res
				return
			}
			v4raw, err := p.get(r.URL + "/show/bgp-ipv4")
			if err != nil {
				ch <- res
				return
			}
			v4, err := decodeIPv4(v4raw)
			if err != nil {
				ch <- res
				return
			}
			res.ok = true
			res.summary = sum
			res.ipv4 = v4
			ch <- res
		}(r)
	}
	wg.Wait()
	close(ch)

	got := map[string]result{}
	for r := range ch {
		got[r.name] = r
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	snap := Snapshot{
		TS:   nowRFC3339ms(now),
		Poll: p.poll.String(),
	}
	var sessions []Session
	var routes []Route

	for _, cfg := range p.routers {
		res := got[cfg.Name]
		rt := Router{Name: cfg.Name, URL: cfg.URL, Reachable: res.ok}
		if res.ok && res.summary.IPv4Unicast != nil {
			fam := res.summary.IPv4Unicast
			rt.ASN = fam.AS
			rt.RouterID = fam.RouterID
			var ss []Session
			for addr, peer := range fam.Peers {
				ss = append(ss, Session{
					Router:   cfg.Name,
					Peer:     addr,
					PeerASN:  peer.RemoteAS,
					State:    peer.State,
					Uptime:   peer.PeerUptime,
					PfxRcd:   peer.PfxRcd,
					PfxSnt:   peer.PfxSnt,
					Hostname: peer.Hostname,
				})
			}
			var rs []Route
			for pfx, paths := range res.ipv4.Routes {
				for _, path := range paths {
					nh := ""
					if len(path.Nexthops) > 0 {
						nh = path.Nexthops[0].IP
					}
					rs = append(rs, Route{
						Router:   cfg.Name,
						Prefix:   pfx,
						Valid:    path.Valid,
						Bestpath: path.Bestpath.Set,
						Nexthop:  nh,
						Path:     path.Path,
						Origin:   path.Origin,
						LocPrf:   path.LocPrf,
						Metric:   path.Metric,
						Weight:   path.Weight,
						PeerID:   path.PeerID,
					})
				}
			}
			p.lastOK[cfg.Name] = routerView{asn: rt.ASN, routerID: rt.RouterID, sessions: ss, routes: rs}
			for _, s := range ss {
				delete(p.held, sessionKey(s))
			}
			sessions = append(sessions, ss...)
			routes = append(routes, rs...)
		} else if res.ok {
			// Answered, but no ipv4Unicast: FRR 10.7.1 prints `{}` with no
			// `router bgp` and `{ }` with an instance and no neighbours
			// (measured 2026-09-20). That is a reachable router with zero
			// sessions, not a lost one: its old sessions take the hold-down
			// below like any vanished peer. Only an unanswered poll replays
			// the last good view as stale.
			p.lastOK[cfg.Name] = routerView{}
		} else if last, ok := p.lastOK[cfg.Name]; ok {
			rt.ASN = last.asn
			rt.RouterID = last.routerID
			for _, s := range last.sessions {
				s.Stale = true
				sessions = append(sessions, s)
			}
			routes = append(routes, last.routes...)
		}
		snap.Routers = append(snap.Routers, rt)
	}

	// Detect peers that vanished from a reachable router's table.
	prevByRouter := map[string][]Session{}
	for _, s := range p.prev.Sessions {
		prevByRouter[s.Router] = append(prevByRouter[s.Router], s)
	}
	liveNow := map[string]bool{}
	for _, s := range sessions {
		liveNow[sessionKey(s)] = true
	}
	for _, rt := range snap.Routers {
		if !rt.Reachable {
			continue
		}
		for _, s := range prevByRouter[rt.Name] {
			k := sessionKey(s)
			if liveNow[k] {
				continue
			}
			if _, ok := p.held[k]; !ok {
				s.State = "Idle"
				s.Stale = false
				s.GoneAt = nowRFC3339ms(now)
				p.held[k] = heldSession{Session: s, goneAt: now}
			}
		}
	}
	for k, h := range p.held {
		if now.Sub(h.goneAt) >= holdDown {
			delete(p.held, k)
			continue
		}
		if liveNow[k] {
			delete(p.held, k)
			continue
		}
		h.State = "Idle"
		sessions = append(sessions, h.Session)
	}

	snap.Sessions = sessions
	snap.Routes = routes
	snap.Nodes, snap.Edges = buildGraph(snap.Routers, sessions, p.asNames)
	for _, r := range snap.Routers {
		if r.Reachable {
			snap.Reachable++
		}
	}
	snap.RouterCount = len(snap.Routers)
	byASN := routerByASN(snap.Routers, p.asNames)
	for _, s := range sessions {
		if _, ok := byASN[s.PeerASN]; ok {
			snap.SessionCount++
			if s.State == "Established" && !s.Stale {
				snap.Established++
			}
		} else {
			snap.ServerSessions++
			if s.State == "Established" && !s.Stale {
				snap.ServerEstablished++
			}
		}
	}
	for _, n := range snap.Nodes {
		if n.Kind == "external" {
			snap.External++
		}
	}

	events := diff(p.prev, snap, now)
	stateChanged := stateSignature(p.prev) != stateSignature(snap)
	p.prev = snap
	p.ready = true
	return snap, events, stateChanged
}

// stateSignature decides whether a tick is broadcast as type=state. It covers
// the graph (nodes, edges and their states, reachability) AND the routes: a
// route-only change — a withdrawal, a bestpath move, an ECMP path — leaves the
// graph as it was, and the RIB pane would keep showing a prefix the Events
// pane had just reported withdrawn (measured 2026-09-20). Routes are sorted
// first: the slice is built from FRR's JSON maps, whose iteration order is
// random per tick.
func stateSignature(s Snapshot) string {
	return graphSignature(s) + "/" + routeSig(s.Routes)
}

func routeSig(routes []Route) string {
	keys := make([]string, 0, len(routes))
	for _, r := range routes {
		keys = append(keys, fmt.Sprintf("%s|%s|%s|%v|%v|%s|%s|%d|%d|%d|%s",
			r.Router, r.Prefix, r.Nexthop, r.Bestpath, r.Valid, r.Path, r.Origin, r.LocPrf, r.Metric, r.Weight, r.PeerID))
	}
	sort.Strings(keys)
	return strings.Join(keys, ";")
}

func graphSignature(s Snapshot) string {
	return fmt.Sprintf("%d/%d/%d/%s/%s", len(s.Nodes), len(s.Edges), s.Reachable, edgeSig(s.Edges), nodeSig(s.Nodes))
}

func edgeSig(edges []Edge) string {
	out := ""
	for _, e := range edges {
		out += e.ID + ":" + e.State + ";"
	}
	return out
}

func nodeSig(nodes []Node) string {
	out := ""
	for _, n := range nodes {
		out += n.ID + ":" + n.Kind + ";"
	}
	return out
}

func (p *poller) get(url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	res, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", url, res.Status)
	}
	return body, nil
}

func (p *poller) snapshot() (Snapshot, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.prev, p.ready
}
