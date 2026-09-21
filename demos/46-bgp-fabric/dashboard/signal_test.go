package main

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// summaryWithCounters builds a one-peer summary carrying the counters the
// signal fields are computed from.
func summaryWithCounters(addr, state string, msgRcvd, msgSent, pfxRcd, pfxSnt int, dynamic bool, tableVersion int) string {
	return fmt.Sprintf(`{"ipv4Unicast":{"routerId":"10.200.255.11","as":65101,"tableVersion":%d,"totalPeers":1,"dynamicPeers":%d,"failedPeers":0,"peers":{
	 %q:{"remoteAs":65100,"state":%q,"peerUptime":"00:01:00","msgRcvd":%d,"msgSent":%d,"inq":0,"outq":0,"pfxRcd":%d,"pfxSnt":%d,"tableVersion":%d,"connectionsDropped":3,"dynamicPeer":%v}}}}`,
		tableVersion, boolToInt(dynamic), addr, state, msgRcvd, msgSent, pfxRcd, pfxSnt, tableVersion, dynamic)
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// The fixture is the live fabric's own answer, trimmed to the fields the
// decoder reads (leaf1, 2026-09-21): one configured fabric peer and the two
// kube-vip nodes that arrived through the listen range.
//
// Both dashboard copies carry this same recording, Colima addresses and all.
// It is a recording of what FRR emits, not a statement about either lab's
// addressing, and the Desktop lab is shut down — inventing a 172.19.x variant
// of it would be writing data rather than measuring it.
func TestDecodeNeighborsReadsTheLiveFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/bgp-neighbors-established.json")
	if err != nil {
		t.Fatal(err)
	}
	n, err := decodeNeighbors(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(n) != 3 {
		t.Fatalf("peers=%d want 3", len(n))
	}
	fabric, ok := n["10.200.1.3"]
	if !ok {
		t.Fatal("fabric peer 10.200.1.3 missing")
	}
	if fabric.HoldMsec != 9000 || fabric.KeepaliveMsec != 3000 {
		t.Fatalf("fabric timers hold=%d keepalive=%d want 9000/3000", fabric.HoldMsec, fabric.KeepaliveMsec)
	}
	// A configured neighbour is in no peer-group; only the listen-range peers are.
	if fabric.PeerGroup != "" {
		t.Fatalf("fabric peerGroup=%q want empty", fabric.PeerGroup)
	}
	node, ok := n["172.20.0.3"]
	if !ok {
		t.Fatal("cluster peer 172.20.0.3 missing")
	}
	if node.PeerGroup != "SERVERS" {
		t.Fatalf("cluster peerGroup=%q want SERVERS", node.PeerGroup)
	}
	// bgpTimerLastRead is the heartbeat. It must survive decoding as a number
	// of milliseconds, not be dropped to zero by a name mismatch.
	if node.LastReadMsec != 1000 {
		t.Fatalf("lastRead=%d want 1000", node.LastReadMsec)
	}
}

// Rule 1 of the signal contract: no delta, no motion. The first tick of a
// session has nothing to subtract, so it must report HasDelta=false rather
// than a zero the page would read as silence.
func TestFirstTickHasNoDelta(t *testing.T) {
	f := newFakeRouter(t)
	f.set(summaryWithCounters("10.200.1.3", "Established", 100, 100, 1, 1, false, 10), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65100: "spine", 65101: "leaf1"}, 2*time.Second)
	t0 := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)

	snap, _, _ := p.tick(t0)
	if snap.Sessions[0].HasDelta {
		t.Fatalf("first tick must not claim a delta: %+v", snap.Sessions[0])
	}
	if snap.Routers[0].HasDelta {
		t.Fatal("first tick must not claim a router delta")
	}

	f.set(summaryWithCounters("10.200.1.3", "Established", 104, 103, 3, 1, false, 14), "")
	snap, _, _ = p.tick(t0.Add(2 * time.Second))
	s := snap.Sessions[0]
	if !s.HasDelta || s.DRcvd != 4 || s.DSent != 3 || s.DPfxRcd != 2 || s.DPfxSnt != 0 {
		t.Fatalf("second tick deltas wrong: hasDelta=%v dRcvd=%d dSent=%d dPfxRcd=%d dPfxSnt=%d",
			s.HasDelta, s.DRcvd, s.DSent, s.DPfxRcd, s.DPfxSnt)
	}
	if r := snap.Routers[0]; !r.HasDelta || r.DTableVersion != 4 {
		t.Fatalf("router delta wrong: hasDelta=%v dTableVersion=%d", r.HasDelta, r.DTableVersion)
	}
	if s.Flaps != 3 {
		t.Fatalf("flaps=%d want 3 (FRR's connectionsDropped)", s.Flaps)
	}
}

// A session that resets restarts its counters at zero. Subtracting the old
// sample would give a negative "pulse"; clamping it to zero would report
// silence on the very tick the session came back. Neither is a measurement,
// so the tick reports no delta and lets Flaps carry the event.
func TestCounterResetReportsNoDeltaRatherThanANegativeOne(t *testing.T) {
	f := newFakeRouter(t)
	f.set(summaryWithCounters("10.200.1.3", "Established", 5000, 5000, 4, 4, false, 90), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65100: "spine", 65101: "leaf1"}, 2*time.Second)
	t0 := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	p.tick(t0)

	f.set(summaryWithCounters("10.200.1.3", "Established", 2, 2, 0, 0, false, 91), "")
	snap, _, _ := p.tick(t0.Add(2 * time.Second))
	s := snap.Sessions[0]
	if s.HasDelta {
		t.Fatalf("a counter reset is not a measurable interval: dRcvd=%d dSent=%d", s.DRcvd, s.DSent)
	}
	if s.DRcvd != 0 || s.DSent != 0 {
		t.Fatalf("no delta must mean no numbers: dRcvd=%d dSent=%d", s.DRcvd, s.DSent)
	}
}

// When the agent stops answering, the previous sample is replayed as stale.
// Measuring the next good poll against it would report several ticks of
// traffic as one tick's worth, so the returning tick reports no delta.
func TestDeltaIsNotMeasuredAcrossAStaleReplay(t *testing.T) {
	f := newFakeRouter(t)
	f.set(summaryWithCounters("10.200.1.3", "Established", 100, 100, 1, 1, false, 10), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65100: "spine", 65101: "leaf1"}, 2*time.Second)
	t0 := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	p.tick(t0)
	p.tick(t0.Add(2 * time.Second)) // a real delta exists by now

	f.setFailing(true)
	snap, _, _ := p.tick(t0.Add(4 * time.Second))
	if !snap.Sessions[0].Stale {
		t.Fatal("an unanswered poll must replay the session as stale")
	}

	// The agent answers again, its counters far ahead of where they were.
	f.setFailing(false)
	f.set(summaryWithCounters("10.200.1.3", "Established", 500, 500, 1, 1, false, 10), "")
	snap, _, _ = p.tick(t0.Add(6 * time.Second))
	if snap.Sessions[0].HasDelta {
		t.Fatalf("delta claimed across a stale gap: dRcvd=%d", snap.Sessions[0].DRcvd)
	}
}

// FRR prints peerId "(unspec)" for a route the router originated itself. Left
// unhandled it becomes an advertisement arriving from a peer of that name.
func TestAdvertisedByIsEmptyForALocallyOriginatedRoute(t *testing.T) {
	routes := []Route{
		{Router: "leaf1", Prefix: "10.200.255.11/32", Bestpath: true, PeerID: unspecPeer, Nexthop: "0.0.0.0"},
		{Router: "leaf1", Prefix: "10.198.0.10/32", Bestpath: true, PeerID: "172.20.0.4", Nexthop: "172.20.0.4"},
		{Router: "leaf1", Prefix: "10.198.0.10/32", Bestpath: false, PeerID: "172.20.0.3", Nexthop: "172.20.0.3"},
	}
	if got := advertisedBy(routes, "leaf1", "10.200.255.11/32"); got != "" {
		t.Fatalf("own loopback advertisedBy=%q want empty", got)
	}
	// The chosen path, not merely the first one in the slice.
	if got := advertisedBy(routes, "leaf1", "10.198.0.10/32"); got != "172.20.0.4" {
		t.Fatalf("advertisedBy=%q want the bestpath's peer 172.20.0.4", got)
	}
}

// A withdrawal has to read its direction from the previous snapshot: the
// prefix is gone from the new one.
func TestWithdrawalCarriesTheDirectionItArrivedFrom(t *testing.T) {
	prev := Snapshot{Routes: []Route{
		{Router: "leaf1", Prefix: "10.198.0.10/32", Bestpath: true, PeerID: "172.20.0.4", Nexthop: "172.20.0.4"},
	}}
	next := Snapshot{}
	ev := diff(prev, next, time.Now())
	var found *Event
	for i := range ev {
		if ev[i].Kind == "route" {
			found = &ev[i]
		}
	}
	if found == nil {
		t.Fatal("no route event for the withdrawal")
	}
	if found.AdvertisedBy != "172.20.0.4" {
		t.Fatalf("withdrawal advertisedBy=%q want 172.20.0.4", found.AdvertisedBy)
	}
}

// Timers come from a separate call. If it fails the router is still reachable
// and the session says so by carrying no timers, rather than reporting a
// quiet time of zero that would read as "this peer just spoke".
func TestNeighborsFailureLeavesTheRouterReachableWithoutTimers(t *testing.T) {
	f := newFakeRouter(t) // serves no /show/bgp-neighbors
	f.set(summaryWithCounters("10.200.1.3", "Established", 100, 100, 1, 1, false, 10), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65100: "spine", 65101: "leaf1"}, 2*time.Second)
	snap, _, _ := p.tick(time.Now())
	if !snap.Routers[0].Reachable {
		t.Fatal("a missing neighbors call must not make the router unreachable")
	}
	s := snap.Sessions[0]
	if s.HasTimers {
		t.Fatal("HasTimers must be false when the call did not answer")
	}
	if s.QuietMsec != 0 || s.HoldMsec != 0 {
		t.Fatalf("no timers must mean no numbers: quiet=%d hold=%d", s.QuietMsec, s.HoldMsec)
	}

	f.setNeighbors(`{"10.200.1.3":{"bgpTimerHoldTimeMsecs":9000,"bgpTimerKeepAliveIntervalMsecs":3000,"bgpTimerLastRead":2000,"peerGroup":"SERVERS"}}`)
	snap, _, _ = p.tick(time.Now())
	s = snap.Sessions[0]
	if !s.HasTimers || s.QuietMsec != 2000 || s.HoldMsec != 9000 || s.KeepaliveMsec != 3000 || s.PeerGroup != "SERVERS" {
		t.Fatalf("timers not carried: %+v", s)
	}
}

// The age belongs to the moment the snapshot is SERVED. A page that animates
// while this climbs is animating data that stopped arriving.
func TestSnapshotAgeIsMeasuredAtServeTime(t *testing.T) {
	f := newFakeRouter(t)
	f.set(summaryWithCounters("10.200.1.3", "Established", 100, 100, 1, 1, false, 10), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65100: "spine", 65101: "leaf1"}, 2*time.Second)
	t0 := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	p.tick(t0)

	if snap, _ := p.snapshotAt(t0); snap.AgeMsec != 0 {
		t.Fatalf("age at the tick itself = %d want 0", snap.AgeMsec)
	}
	if snap, _ := p.snapshotAt(t0.Add(7500 * time.Millisecond)); snap.AgeMsec != 7500 {
		t.Fatalf("age = %d want 7500", snap.AgeMsec)
	}
}

// dynamicPeer is how FRR says "this peer arrived through the listen range",
// which on this fabric means a cluster node. It is the difference between a
// leaf that is accepting traffic and one that is merely up.
func TestDynamicPeerIsCarriedThrough(t *testing.T) {
	f := newFakeRouter(t)
	f.set(summaryWithCounters("172.20.0.3", "Established", 100, 100, 1, 0, true, 84), "")
	p := newPoller([]RouterCfg{{Name: "leaf1", URL: f.srv.URL}}, map[int]string{65021: "eg-poc1", 65101: "leaf1"}, 2*time.Second)
	snap, _, _ := p.tick(time.Now())
	if !snap.Sessions[0].Dynamic {
		t.Fatal("dynamicPeer not carried onto the session")
	}
	if snap.Routers[0].DynamicPeers != 1 {
		t.Fatalf("router dynamicPeers=%d want 1", snap.Routers[0].DynamicPeers)
	}
}
