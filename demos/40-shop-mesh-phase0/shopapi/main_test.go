package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHealthz(t *testing.T) {
	t.Setenv("CLUSTER", "poc1")
	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	newMux(nil).ServeHTTP(w, r)
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
	db, err := openDB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	r := httptest.NewRequest(http.MethodGet, "/ready", nil)
	w := httptest.NewRecorder()
	newMux(db).ServeHTTP(w, r)
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
	newMux(nil).ServeHTTP(w, r)
	if got := w.Result().Header.Get("X-Served-By"); got != "unknown" {
		t.Fatalf("X-Served-By = %q, want unknown when CLUSTER is unset", got)
	}
}

func TestMalformedDBURLFailsAtStartup(t *testing.T) {
	t.Setenv("DB_URL", "postgres://shop:shop@127.0.0.1:notaport/shop")
	if _, err := openDB(); err == nil {
		t.Fatal("want openDB to reject a malformed DB_URL at startup")
	}
}

func TestDBErrorsAndIdentityUseSharedPool(t *testing.T) {
	t.Setenv("CLUSTER", "poc2")
	t.Setenv("DB_URL", "postgres://shop:shop@127.0.0.1:1/shop?sslmode=disable&connect_timeout=99")

	db, err := openDB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h := newMux(db)

	for _, path := range []string{"/ready", "/orders"} {
		start := time.Now()
		r := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)

		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status=%d body=%q", path, w.Code, w.Body.String())
		}
		if time.Since(start) > 3*time.Second {
			t.Fatalf("%s exceeded the DB deadline", path)
		}
		if w.Header().Get("X-Served-By") != "poc2" ||
			w.Header().Get("X-Pod") == "" ||
			w.Body.Len() == 0 {
			t.Fatalf("%s headers=%v body=%q", path, w.Header(), w.Body.String())
		}
	}

	r := httptest.NewRequest(http.MethodGet, "/missing", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound || w.Header().Get("X-Served-By") != "poc2" {
		t.Fatalf("404 status=%d headers=%v", w.Code, w.Header())
	}
}
