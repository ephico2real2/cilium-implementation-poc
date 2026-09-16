package main

import (
	"html"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWantsHTML(t *testing.T) {
	tests := []struct {
		name   string
		accept string
		want   bool
	}{
		{"curl */*", "*/*", false},
		{"chrome", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", true},
		{"application/json", "application/json", false},
		{"json before html", "application/json, text/html", false},
		{"empty", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			if tt.accept != "" {
				r.Header.Set("Accept", tt.accept)
			}
			if got := wantsHTML(r); got != tt.want {
				t.Fatalf("wantsHTML(%q) = %v, want %v", tt.accept, got, tt.want)
			}
		})
	}
}

func TestRootJSONNegotiation(t *testing.T) {
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
		if !strings.Contains(html.UnescapeString(body), `"app"`) {
			t.Fatalf("want indented key \"app\", got %s", body)
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
