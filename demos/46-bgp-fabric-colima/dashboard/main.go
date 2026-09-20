package main

import (
	"context"
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

//go:embed static
var staticFS embed.FS

const (
	defaultRouters = "edge=http://10.200.200.1:8080,spine=http://10.200.200.2:8080,leaf1=http://10.200.200.11:8080,leaf2=http://10.200.200.12:8080"
	defaultASNames = "65000=edge,65100=spine,65101=leaf1,65102=leaf2,65021=eg-poc1 (kube-vip),65022=eg-poc2 (MetalLB),65001=poc1 (Cilium),65002=poc2 (Cilium)"
	defaultPoll    = 2 * time.Second
	defaultListen  = ":8080"
	defaultEvents  = 500
)

type hub struct {
	mu      sync.Mutex
	clients map[*wsClient]struct{}
	poller  *poller
	events  []Event
	nextID  int
	ring    int
}

type wsClient struct {
	c    *websocket.Conn
	send chan []byte
}

func newHub(p *poller, ring int) *hub {
	return &hub{
		clients: map[*wsClient]struct{}{},
		poller:  p,
		ring:    ring,
	}
}

func (h *hub) addEvent(ev Event) Event {
	h.nextID++
	ev.ID = h.nextID
	h.events = append(h.events, ev)
	if len(h.events) > h.ring {
		h.events = h.events[len(h.events)-h.ring:]
	}
	return ev
}

func (h *hub) eventsSince(id int) []Event {
	out := []Event{}
	for _, e := range h.events {
		if e.ID > id {
			out = append(out, e)
		}
	}
	return out
}

func (h *hub) broadcast(msg []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for cl := range h.clients {
		select {
		case cl.send <- msg:
		default:
			close(cl.send)
			delete(h.clients, cl)
		}
	}
}

func (h *hub) register(cl *wsClient) {
	h.mu.Lock()
	h.clients[cl] = struct{}{}
	h.mu.Unlock()
}

func (h *hub) unregister(cl *wsClient) {
	h.mu.Lock()
	if _, ok := h.clients[cl]; ok {
		delete(h.clients, cl)
		// send may already be closed by broadcast
	}
	h.mu.Unlock()
}

func parseRouters(s string) []RouterCfg {
	var out []RouterCfg
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		out = append(out, RouterCfg{Name: strings.TrimSpace(k), URL: strings.TrimSpace(v)})
	}
	return out
}

func parseASNames(s string) map[int]string {
	out := map[int]string{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(k))
		if err != nil {
			continue
		}
		out[n] = strings.TrimSpace(v)
	}
	return out
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	listen := envOr("DASHBOARD_LISTEN", defaultListen)
	poll, err := time.ParseDuration(envOr("DASHBOARD_POLL", "2s"))
	if err != nil {
		poll = defaultPoll
	}
	ring := defaultEvents
	if v := os.Getenv("DASHBOARD_EVENTS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			ring = n
		}
	}
	routers := parseRouters(envOr("DASHBOARD_ROUTERS", defaultRouters))
	if len(routers) == 0 {
		log.Fatal("bgp-dashboard: DASHBOARD_ROUTERS is empty")
	}
	asNames := parseASNames(envOr("DASHBOARD_AS_NAMES", defaultASNames))
	p := newPoller(routers, asNames, poll)
	h := newHub(p, ring)

	go func() {
		// first poll immediately so /healthz can pass
		h.runTick()
		t := time.NewTicker(poll)
		defer t.Stop()
		for range t.C {
			h.runTick()
		}
	}()

	static, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServer(http.FS(static)))
	mux.HandleFunc("GET /api/state", h.apiState)
	mux.HandleFunc("GET /api/events", h.apiEvents)
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /ws", h.ws)
	log.Printf("bgp-dashboard: listen %s poll %s routers %d", listen, poll, len(routers))
	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func (h *hub) runTick() {
	snap, events, stateChanged := h.poller.tick(time.Now())
	h.mu.Lock()
	var evMsgs [][]byte
	for _, ev := range events {
		// one shape for one object: the ring (/api/events) and the socket
		// frame carry the same Type
		ev.Type = "event"
		ev = h.addEvent(ev)
		b, err := json.Marshal(ev)
		if err == nil {
			evMsgs = append(evMsgs, b)
		}
	}
	h.mu.Unlock()
	for _, b := range evMsgs {
		h.broadcast(b)
	}
	if stateChanged {
		snap.Type = "state"
		if b, err := json.Marshal(snap); err == nil {
			h.broadcast(b)
		}
	}
}

func (h *hub) apiState(w http.ResponseWriter, _ *http.Request) {
	snap, _ := h.poller.snapshot()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(snap)
}

func (h *hub) apiEvents(w http.ResponseWriter, r *http.Request) {
	since := 0
	if v := r.URL.Query().Get("since"); v != "" {
		since, _ = strconv.Atoi(v)
	}
	h.mu.Lock()
	ev := h.eventsSince(since)
	h.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(ev)
}

func (h *hub) healthz(w http.ResponseWriter, _ *http.Request) {
	snap, ready := h.poller.snapshot()
	w.Header().Set("Cache-Control", "no-store")
	if !ready || snap.Reachable < snap.RouterCount || snap.RouterCount == 0 {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (h *hub) ws(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	cl := &wsClient{c: c, send: make(chan []byte, 8)}
	h.register(cl)
	defer func() {
		h.unregister(cl)
		_ = c.CloseNow()
	}()

	// The browser only listens. CloseRead drains the socket so ping/pong and
	// the client's close frame are answered, and cancels ctx when the peer is
	// gone. Without it the request context outlives the hijacked connection
	// and a closed tab keeps its goroutine until the next broadcast fails.
	ctx := c.CloseRead(r.Context())

	snap, _ := h.poller.snapshot()
	snap.Type = "state"
	if b, err := json.Marshal(snap); err == nil {
		wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err = c.Write(wctx, websocket.MessageText, b)
		cancel()
		if err != nil {
			return
		}
	}

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-cl.send:
			if !ok {
				return
			}
			wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			err := c.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				return
			}
		}
	}
}
