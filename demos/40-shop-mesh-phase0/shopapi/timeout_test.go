package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// A TCP listener that accepts and never answers: pgx's connect handshake waits for the
// startup response, so only a connect timeout in the pool's config (not the 2 s request
// context) can end it early. Before the fix: ~2.0 s (context deadline). After: ~1 s.
func TestReadyConnectTimeoutBoundsSilentServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	t.Setenv("DB_URL", "postgres://shop:shop@"+ln.Addr().String()+"/shop?sslmode=disable")
	db, err := openDB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	r := httptest.NewRequest(http.MethodGet, "/ready", nil)
	w := httptest.NewRecorder()
	start := time.Now()
	newMux(db).ServeHTTP(w, r)
	el := time.Since(start)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", w.Code)
	}
	if el > 1500*time.Millisecond {
		t.Fatalf("/ready took %v against a silent server; want the pool's connect timeout (1 s) to end it, not the 2 s request context", el)
	}
}
