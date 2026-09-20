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
}

type Router struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	ASN       int    `json:"asn"`
	RouterID  string `json:"routerId"`
	Reachable bool   `json:"reachable"`
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
}

type RouterCfg struct {
	Name string
	URL  string
}
