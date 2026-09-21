package main

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Field names below are as FRR 10.7.1 emits them (measured 2026-09-20 on a
// throwaway `quay.io/frrouting/frr:10.7.1` with `show bgp summary json` /
// `show bgp ipv4 unicast json`; Active peer and a locally-originated /32).
// hostname is absent on Active (present on Established — fabric transcript).
// valid / bestpath / locPrf are omitted on a local-originated route that is
// not yet selected; FRR adds `"valid": true` and `"bestpath": true` (boolean)
// when BGP_PATH_VALID / BGP_PATH_SELECTED (bgpd/bgp_route.c @ frr-10.7.1).

type frrSummary struct {
	IPv4Unicast *frrFamily `json:"ipv4Unicast"`
}

type frrFamily struct {
	RouterID string             `json:"routerId"`
	AS       int                `json:"as"`
	Peers    map[string]frrPeer `json:"peers"`
}

type frrPeer struct {
	RemoteAS   int    `json:"remoteAs"`
	State      string `json:"state"`
	PeerUptime string `json:"peerUptime"`
	PfxRcd     int    `json:"pfxRcd"`
	PfxSnt     int    `json:"pfxSnt"`
	Hostname   string `json:"hostname"`
	IDType     string `json:"idType"`
}

type frrIPv4 struct {
	RouterID string                   `json:"routerId"`
	LocalAS  int                      `json:"localAS"`
	Routes   map[string][]frrPathJSON `json:"routes"`
}

type frrPathJSON struct {
	Valid    bool         `json:"valid"`
	Bestpath bestpathFlag `json:"bestpath"`
	Nexthops []frrNexthop `json:"nexthops"`
	Path     string       `json:"path"`
	Origin   string       `json:"origin"`
	LocPrf   int          `json:"locPrf"`
	Metric   int          `json:"metric"`
	Weight   int          `json:"weight"`
	PeerID   string       `json:"peerId"`
	Network  string       `json:"network"`
}

type frrNexthop struct {
	IP string `json:"ip"`
}

// bestpathFlag accepts FRR's boolean (`true` on the table view) and the
// object form used by the detail view.
type bestpathFlag struct {
	Set bool
}

func (b *bestpathFlag) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || bytes.Equal(data, []byte("null")) || bytes.Equal(data, []byte("false")) {
		b.Set = false
		return nil
	}
	if bytes.Equal(data, []byte("true")) {
		b.Set = true
		return nil
	}
	if data[0] == '{' {
		b.Set = true
		return nil
	}
	return fmt.Errorf("bestpath: %s", data)
}

func decodeSummary(raw []byte) (frrSummary, error) {
	var s frrSummary
	if err := json.Unmarshal(firstJSON(raw), &s); err != nil {
		return s, err
	}
	return s, nil
}

func decodeIPv4(raw []byte) (frrIPv4, error) {
	var t frrIPv4
	if err := json.Unmarshal(firstJSON(raw), &t); err != nil {
		return t, err
	}
	return t, nil
}

func firstJSON(raw []byte) []byte {
	i := bytes.IndexByte(raw, '{')
	if i < 0 {
		return raw
	}
	return raw[i:]
}
