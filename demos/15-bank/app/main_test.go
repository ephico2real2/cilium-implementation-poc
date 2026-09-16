package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWriteJSONUsesJSONView(t *testing.T) {
	payload := map[string]any{"account": "chk-1001", "served_by": me("api")}

	t.Run("html", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/api/balance/chk-1001", nil)
		r.Header.Set("Accept", "text/html")
		w := httptest.NewRecorder()
		writeJSON(w, r, http.StatusOK, payload)
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
		r := httptest.NewRequest(http.MethodGet, "/api/balance/chk-1001", nil)
		w := httptest.NewRecorder()
		writeJSON(w, r, http.StatusOK, payload)
		res := w.Result()
		body := w.Body.Bytes()
		if ct := res.Header.Get("Content-Type"); ct != "application/json" {
			t.Fatalf("Content-Type = %q, want application/json", ct)
		}
		want, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		want = append(want, '\n')
		if string(body) != string(want) {
			t.Fatalf("compact body = %q, want %q", body, want)
		}
	})
}
