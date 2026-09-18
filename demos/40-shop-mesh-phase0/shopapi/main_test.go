package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	t.Setenv("CLUSTER", "poc1")
	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	newMux().ServeHTTP(w, r)
	res := w.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	if body := strings.TrimSpace(w.Body.String()); body != "ok" {
		t.Fatalf("body = %q, want ok", body)
	}
	if got := res.Header.Get("X-Served-By"); got != "poc1" {
		t.Fatalf("X-Served-By = %q, want poc1", got)
	}
	if got := res.Header.Get("X-Pod"); got == "" {
		t.Fatal("X-Pod is empty")
	}
}

func TestReadyUnreachableDB(t *testing.T) {
	t.Setenv("CLUSTER", "poc2")
	t.Setenv("DB_URL", "postgres://shop:shop@127.0.0.1:1/shop?sslmode=disable&connect_timeout=1")
	r := httptest.NewRequest(http.MethodGet, "/ready", nil)
	w := httptest.NewRecorder()
	newMux().ServeHTTP(w, r)
	res := w.Result()
	if res.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body %q", res.StatusCode, w.Body.String())
	}
	if got := res.Header.Get("X-Served-By"); got != "poc2" {
		t.Fatalf("X-Served-By = %q, want poc2", got)
	}
	if w.Body.Len() == 0 {
		t.Fatal("503 body is empty; want the error text")
	}
}

func TestHealthzDefaultCluster(t *testing.T) {
	os.Unsetenv("CLUSTER")
	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	newMux().ServeHTTP(w, r)
	if got := w.Result().Header.Get("X-Served-By"); got != "unknown" {
		t.Fatalf("X-Served-By = %q, want unknown when CLUSTER is unset", got)
	}
}
