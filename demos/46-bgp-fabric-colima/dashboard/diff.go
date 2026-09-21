package main

import (
	"fmt"
	"time"
)

func nowRFC3339ms(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

func sessionKey(s Session) string { return s.Router + "|" + s.Peer }
func routeKey(r Route) string     { return r.Router + "|" + r.Prefix }

func bestNexthop(routes []Route, router, prefix string) (string, bool) {
	for _, r := range routes {
		if r.Router == router && r.Prefix == prefix && r.Bestpath {
			return r.Nexthop, true
		}
	}
	return "", false
}

// diff compares two snapshots and returns events. Pure; coalesces nothing.
func diff(prev, next Snapshot, ts time.Time) []Event {
	when := nowRFC3339ms(ts)
	var ev []Event

	prevR := map[string]Router{}
	for _, r := range prev.Routers {
		prevR[r.Name] = r
	}
	for _, r := range next.Routers {
		p, ok := prevR[r.Name]
		if !ok {
			continue
		}
		if p.Reachable && !r.Reachable {
			ev = append(ev, Event{TS: when, Kind: "router", Router: r.Name, From: "reachable", To: "unreachable",
				Text: "router " + r.Name + " unreachable"})
		}
		if !p.Reachable && r.Reachable {
			ev = append(ev, Event{TS: when, Kind: "router", Router: r.Name, From: "unreachable", To: "reachable",
				Text: "router " + r.Name + " reachable again"})
		}
	}

	prevS := map[string]Session{}
	for _, s := range prev.Sessions {
		prevS[sessionKey(s)] = s
	}
	nextS := map[string]Session{}
	for _, s := range next.Sessions {
		nextS[sessionKey(s)] = s
		p, ok := prevS[sessionKey(s)]
		if !ok {
			ev = append(ev, Event{TS: when, Kind: "session", Router: s.Router, Peer: s.Peer, From: "", To: s.State,
				Text: fmt.Sprintf("%s %s appeared %s", s.Router, s.Peer, s.State)})
			continue
		}
		if p.State != s.State {
			ev = append(ev, Event{TS: when, Kind: "session", Router: s.Router, Peer: s.Peer, From: p.State, To: s.State,
				Text: fmt.Sprintf("%s %s %s → %s", s.Router, s.Peer, p.State, s.State)})
		}
	}
	for k, p := range prevS {
		if _, ok := nextS[k]; !ok {
			ev = append(ev, Event{TS: when, Kind: "session", Router: p.Router, Peer: p.Peer, From: p.State, To: "",
				Text: fmt.Sprintf("%s %s vanished (was %s)", p.Router, p.Peer, p.State)})
		}
	}

	prevRoutes := map[string][]Route{}
	for _, r := range prev.Routes {
		prevRoutes[r.Router] = append(prevRoutes[r.Router], r)
	}
	nextByPrefix := map[string]bool{}
	for _, r := range next.Routes {
		k := routeKey(r)
		if nextByPrefix[k] {
			// one Route per path (ECMP): the prefix is "added" once, not per path
			// (measured 2026-09-20: 10.198.0.11/32 on leaf2 logged three times)
			continue
		}
		nextByPrefix[k] = true
		found := false
		for _, p := range prev.Routes {
			if routeKey(p) == k {
				found = true
				break
			}
		}
		if !found {
			ev = append(ev, Event{TS: when, Kind: "route", Router: r.Router, Prefix: r.Prefix,
				Text: fmt.Sprintf("%s: %s added via %s", r.Router, r.Prefix, r.Nexthop)})
		}
	}
	seenPrevPrefix := map[string]bool{}
	for _, p := range prev.Routes {
		k := routeKey(p)
		if seenPrevPrefix[k] {
			continue
		}
		seenPrevPrefix[k] = true
		if !nextByPrefix[k] {
			ev = append(ev, Event{TS: when, Kind: "route", Router: p.Router, Prefix: p.Prefix,
				Text: fmt.Sprintf("%s: %s withdrawn", p.Router, p.Prefix)})
		} else {
			oldNH, oldOK := bestNexthop(prev.Routes, p.Router, p.Prefix)
			newNH, newOK := bestNexthop(next.Routes, p.Router, p.Prefix)
			if oldOK && newOK && oldNH != newNH {
				ev = append(ev, Event{TS: when, Kind: "route", Router: p.Router, Prefix: p.Prefix, From: oldNH, To: newNH,
					Text: fmt.Sprintf("%s: %s bestpath via %s → %s", p.Router, p.Prefix, oldNH, newNH)})
			}
		}
	}
	return ev
}
