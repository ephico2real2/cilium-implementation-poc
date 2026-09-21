package main

// Snapshot is the JSON the browser and /api/state consume.
type Snapshot struct {
	Type         string    `json:"type,omitempty"`
	TS           string    `json:"ts"`
	Poll         string    `json:"poll"`
	Routers      []Router  `json:"routers"`
	Nodes        []Node    `json:"nodes"`
	Edges        []Edge    `json:"edges"`
	Sessions     []Session `json:"sessions"`
	Routes       []Route   `json:"routes"`
	Reachable    int       `json:"reachable"`
	RouterCount  int       `json:"routerCount"`
	Established  int       `json:"established"`
	SessionCount int       `json:"sessionCount"`
	External     int       `json:"external"`
	// sessions with the servers (the dynamic neighbours: kube-vip, MetalLB, Cilium)
	ServerSessions    int `json:"serverSessions"`
	ServerEstablished int `json:"serverEstablished"`
	// AgeMsec is filled in when the snapshot is SERVED, not when it is taken:
	// it is how stale the data the browser is holding actually is. The browser
	// cannot compute this from TS without trusting its own clock against the
	// server's. A page that keeps animating while this climbs is lying.
	AgeMsec int64 `json:"ageMsec"`
}

type Router struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	ASN       int    `json:"asn"`
	RouterID  string `json:"routerId"`
	Reachable bool   `json:"reachable"`
	// LastSeen is the time of the last successful poll of this agent.
	// Frozen while the router is unreachable so the page can say
	// "cannot reach leaf2 — last seen 12s ago" instead of treating
	// last-known RIB rows as live. Empty if the agent has never answered.
	LastSeen string `json:"lastSeen,omitempty"`

	// TableVersion is this router's own "something changed" counter. FRR
	// repeats it on every peer in the summary; it belongs to the router.
	TableVersion int `json:"tableVersion"`
	// DTableVersion is the change since the previous tick — the honest input
	// for a per-router heartbeat. HasDelta is false on the first tick.
	HasDelta      bool `json:"hasDelta"`
	DTableVersion int  `json:"dTableVersion"`
	// DynamicPeers counts peers that arrived through a listen range: non-zero
	// means a cluster is peering with this router right now.
	DynamicPeers int `json:"dynamicPeers"`
	FailedPeers  int `json:"failedPeers"`
	PeerCount    int `json:"peerCount"`
}

type Node struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"` // router | external
	Label string `json:"label"`
	ASN   int    `json:"asn"`
	Addr  string `json:"addr,omitempty"`
}

type Edge struct {
	ID      string `json:"id"`
	Source  string `json:"source"`
	Target  string `json:"target"`
	State   string `json:"state"` // established | transitional | down | stale
	ARouter string `json:"aRouter,omitempty"`
	BRouter string `json:"bRouter,omitempty"`
	APeer   string `json:"aPeer,omitempty"`
	BPeer   string `json:"bPeer,omitempty"`
	AUptime string `json:"aUptime,omitempty"`
	BUptime string `json:"bUptime,omitempty"`
	APfxRcd int    `json:"aPfxRcd"`
	BPfxRcd int    `json:"bPfxRcd"`
	APfxSnt int    `json:"aPfxSnt"`
	BPfxSnt int    `json:"bPfxSnt"`
	AState  string `json:"aState,omitempty"`
	BState  string `json:"bState,omitempty"`
}

type Session struct {
	Router   string `json:"router"`
	Peer     string `json:"peer"`
	PeerASN  int    `json:"peerAsn"`
	State    string `json:"state"`
	Uptime   string `json:"uptime"`
	PfxRcd   int    `json:"pfxRcd"`
	PfxSnt   int    `json:"pfxSnt"`
	Hostname string `json:"hostname,omitempty"`
	Stale    bool   `json:"stale,omitempty"`
	GoneAt   string `json:"goneAt,omitempty"`

	// SIGNAL — what the session is doing, not merely what state it is in.
	// An Established line tells you the peers agreed to talk; these tell you
	// whether anything is being said.

	MsgRcvd int `json:"msgRcvd"`
	MsgSent int `json:"msgSent"`
	// InQ/OutQ non-zero is a session talking but not draining: congestion,
	// not silence.
	InQ  int `json:"inq"`
	OutQ int `json:"outq"`
	// Flaps is FRR's connectionsDropped: how often this peer has gone down
	// since bgpd started, including drops between two of our polls.
	Flaps int `json:"flaps"`
	// Dynamic marks a peer that arrived through `bgp listen range`. On this
	// fabric that is exactly a cluster node, so a leaf with Dynamic peers is
	// accepting traffic from a cluster and one without is up but idle.
	Dynamic   bool   `json:"dynamic,omitempty"`
	PeerGroup string `json:"peerGroup,omitempty"`

	// HasDelta is false on the first tick of a session, when there is no
	// previous sample to subtract. The page must render "unknown" then, not a
	// zero that looks like silence.
	HasDelta bool `json:"hasDelta"`
	DRcvd    int  `json:"dRcvd"`
	DSent    int  `json:"dSent"`
	DPfxRcd  int  `json:"dPfxRcd"`
	DPfxSnt  int  `json:"dPfxSnt"`

	// HasTimers is false when `show bgp neighbors` did not answer, so the
	// three fields below carry no measurement rather than a zero.
	//
	// QuietMsec is FRR's own bgpTimerLastRead: milliseconds since this peer
	// last said anything. It is the heartbeat, and it is measured by the
	// router, not inferred from our sampling. Healthy, it sawtooths between 0
	// and KeepaliveMsec; climbing past that means a keepalive was missed, and
	// at HoldMsec FRR tears the session down. So a session cannot be silent
	// for long on this fabric — the useful reading is not "silent forever" but
	// how far through the hold time this peer already is.
	HasTimers     bool `json:"hasTimers"`
	QuietMsec     int  `json:"quietMsec"`
	HoldMsec      int  `json:"holdMsec"`
	KeepaliveMsec int  `json:"keepaliveMsec"`
}

type Route struct {
	Router   string `json:"router"`
	Prefix   string `json:"prefix"`
	Valid    bool   `json:"valid"`
	Bestpath bool   `json:"bestpath"`
	Nexthop  string `json:"nexthop"`
	Path     string `json:"path"`
	Origin   string `json:"origin"`
	LocPrf   int    `json:"locPrf,omitempty"`
	Metric   int    `json:"metric,omitempty"`
	Weight   int    `json:"weight"`
	PeerID   string `json:"peerId"`
}

type Event struct {
	Type   string `json:"type,omitempty"`
	ID     int    `json:"id"`
	TS     string `json:"ts"`
	Kind   string `json:"kind"` // session | router | route
	Router string `json:"router"`
	Peer   string `json:"peer,omitempty"`
	Prefix string `json:"prefix,omitempty"`
	From   string `json:"from,omitempty"`
	To     string `json:"to,omitempty"`
	Text   string `json:"text"`
	// AdvertisedBy is the peer a route event arrived from (FRR's peerId on the
	// bestpath). It is what lets the page animate the edge in the direction
	// the advertisement travelled instead of guessing. Empty for a route the
	// router originated itself, and for session and router events.
	AdvertisedBy string `json:"advertisedBy,omitempty"`
}

type RouterCfg struct {
	Name string
	URL  string
}
