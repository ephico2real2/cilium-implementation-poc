package jsonview

import (
	"encoding/json"
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
			if got := WantsHTML(r); got != tt.want {
				t.Fatalf("WantsHTML(%q) = %v, want %v", tt.accept, got, tt.want)
			}
		})
	}
}

func TestWrite(t *testing.T) {
	compact := []byte(`{"app":"demo","n":1}` + "\n")

	t.Run("html", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Accept", "text/html")
		w := httptest.NewRecorder()
		Write(w, r, http.StatusOK, compact, "demo")
		res := w.Result()
		body := w.Body.String()
		if ct := res.Header.Get("Content-Type"); ct != "text/html; charset=utf-8" {
			t.Fatalf("Content-Type = %q, want text/html; charset=utf-8", ct)
		}
		if !strings.Contains(body, "<pre>") {
			t.Fatalf("want <pre> in body, got %s", body)
		}
		if !strings.Contains(body, `<span class="k">`) {
			t.Fatalf("want syntax-coloured keys, got %s", body)
		}
		if !strings.Contains(body, "GET /") {
			t.Fatalf("want method and path in header, got %s", body)
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
		Write(w, r, http.StatusOK, compact, "demo")
		res := w.Result()
		body := w.Body.String()
		if ct := res.Header.Get("Content-Type"); ct != "application/json" {
			t.Fatalf("Content-Type = %q, want application/json", ct)
		}
		if strings.Contains(body, "<pre>") {
			t.Fatalf("compact path must not wrap HTML, got %s", body)
		}
		if body != string(compact) {
			t.Fatalf("compact body = %q, want %q", body, compact)
		}
		if !strings.HasSuffix(body, "\n") {
			t.Fatalf("want trailing newline, got %q", body)
		}
		if res.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", res.StatusCode)
		}
	})
}

func TestWriteValue(t *testing.T) {
	payload := map[string]any{"account": "chk-1001", "n": 1}

	t.Run("html", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/api/balance/chk-1001", nil)
		r.Header.Set("Accept", "text/html")
		w := httptest.NewRecorder()
		WriteValue(w, r, http.StatusOK, payload, "api")
		res := w.Result()
		body := w.Body.String()
		if ct := res.Header.Get("Content-Type"); ct != "text/html; charset=utf-8" {
			t.Fatalf("Content-Type = %q, want text/html; charset=utf-8", ct)
		}
		if !strings.Contains(body, "<pre>") {
			t.Fatalf("want <pre> in body, got %s", body)
		}
		if !strings.Contains(body, `<span class="k">`) {
			t.Fatalf("want syntax-coloured keys, got %s", body)
		}
		if !strings.Contains(body, "GET /api/balance/chk-1001") {
			t.Fatalf("want method and path in header, got %s", body)
		}
		if !strings.Contains(html.UnescapeString(body), `"account"`) {
			t.Fatalf("want indented key \"account\", got %s", body)
		}
		if res.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", res.StatusCode)
		}
	})
	t.Run("compact", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/api/balance/chk-1001", nil)
		w := httptest.NewRecorder()
		WriteValue(w, r, http.StatusOK, payload, "api")
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

func TestWritePreservesFieldOrder(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Accept", "text/html")
	w := httptest.NewRecorder()
	Write(w, r, http.StatusOK, []byte(`{"b":1,"a":2}`), "order")
	body := w.Body.String()
	i := strings.Index(body, "<pre>")
	j := strings.Index(body, "</pre>")
	if i < 0 || j < 0 {
		t.Fatalf("want <pre>…</pre> in body, got %s", body)
	}
	pre := html.UnescapeString(body[i:j])
	ib := strings.Index(pre, `"b"`)
	ia := strings.Index(pre, `"a"`)
	if ib < 0 || ia < 0 || ib > ia {
		t.Fatalf("want \"b\" before \"a\" in <pre>, got %s", pre)
	}
}
