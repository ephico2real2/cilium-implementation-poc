package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRootUsesJSONView(t *testing.T) {
	t.Run("html", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Accept", "text/html")
		w := httptest.NewRecorder()
		handleRoot(w, r)
		res := w.Result()
		body := w.Body.String()
		if ct := res.Header.Get("Content-Type"); ct != "text/html; charset=utf-8" {
			t.Fatalf("Content-Type = %q, want text/html; charset=utf-8", ct)
		}
		if !strings.Contains(body, "<pre>") {
			t.Fatalf("want <pre> in body, got %s", body)
		}
		if res.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", res.StatusCode)
		}
	})
	t.Run("compact", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		w := httptest.NewRecorder()
		handleRoot(w, r)
		res := w.Result()
		body := w.Body.String()
		if ct := res.Header.Get("Content-Type"); ct != "application/json" {
			t.Fatalf("Content-Type = %q, want application/json", ct)
		}
		if strings.Contains(body, "<pre>") {
			t.Fatalf("compact path must not wrap HTML, got %s", body)
		}
		if !strings.HasPrefix(body, `{"app":`) || strings.Contains(body, "\n  ") {
			t.Fatalf("want compact JSON, got %s", body)
		}
		if !strings.HasSuffix(body, "\n") {
			t.Fatalf("want trailing newline, got %q", body)
		}
	})
}
