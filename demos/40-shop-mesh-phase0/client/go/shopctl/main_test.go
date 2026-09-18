package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseArgsProbe(t *testing.T) {
	cfg, err := parseArgs([]string{"probe", "--url", "https://api.shop.poc.local", "-k", "--timeout", "1s"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.cmd != "probe" || cfg.url != "https://api.shop.poc.local" || !cfg.insecure || cfg.timeout != time.Second {
		t.Fatalf("parsed %+v", cfg)
	}
}

func TestParseArgsLoadRequiresRateAndDuration(t *testing.T) {
	if _, err := parseArgs([]string{"load", "--url", "https://x"}); err == nil {
		t.Fatal("want error when --rate/--duration missing")
	}
	cfg, err := parseArgs([]string{"load", "--url", "https://x/", "--rate", "5", "--duration", "3s", "--path", "ready"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.rate != 5 || cfg.duration != 3*time.Second || cfg.path != "/ready" || cfg.url != "https://x" {
		t.Fatalf("parsed %+v", cfg)
	}
}

func TestParseArgsURLRequired(t *testing.T) {
	if _, err := parseArgs([]string{"probe"}); err == nil || !strings.Contains(err.Error(), "--url") {
		t.Fatalf("want --url required, got %v", err)
	}
}

func TestAggregateSecondAndExitRule(t *testing.T) {
	hits := []hit{
		{status: 200, served: "poc1"},
		{status: 200, served: "poc2"},
		{status: 500, served: "poc1"},
		{err: io.EOF},
	}
	agg := aggregateSecond(2, hits)
	if agg.ok != 2 || agg.fail != 2 {
		t.Fatalf("ok=%d fail=%d, want 2/2", agg.ok, agg.fail)
	}
	if got := joinServed(agg.served); got != "poc1,poc2" {
		t.Fatalf("served = %q, want poc1,poc2", got)
	}
}

func TestLoadFakeServerExitCode(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.Header().Set("X-Served-By", "test")
		if r.URL.Path != "/healthz" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	}))
	defer srv.Close()

	cfg := &config{url: srv.URL, rate: 4, duration: 2 * time.Second, path: "/healthz", timeout: time.Second}
	client := srv.Client()
	client.Timeout = time.Second
	var buf bytes.Buffer
	code := runLoad(&buf, client, cfg)
	out := buf.String()
	if code != 0 {
		t.Fatalf("exit %d, want 0; output:\n%s", code, out)
	}
	if !strings.Contains(out, "SECOND") || !strings.Contains(out, "X-SERVED-BY") || !strings.Contains(out, "latency_ms") {
		t.Fatalf("missing table columns:\n%s", out)
	}
	if !strings.Contains(out, "test") {
		t.Fatalf("want X-Served-By test in output:\n%s", out)
	}

	cfg.path = "/missing"
	buf.Reset()
	code = runLoad(&buf, client, cfg)
	if code != 2 {
		t.Fatalf("fail-seconds exit %d, want 2 (duration); output:\n%s", code, buf.String())
	}
}

func TestProbeFakeServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Served-By", "poc1")
		switch r.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}))
	defer srv.Close()
	var buf bytes.Buffer
	code := runProbe(&buf, srv.Client(), srv.URL)
	if code != 2 {
		t.Fatalf("probe exit %d, want 2 (ready+orders); output:\n%s", code, buf.String())
	}
	if !strings.Contains(buf.String(), "/healthz") || !strings.Contains(buf.String(), "poc1") {
		t.Fatalf("probe table:\n%s", buf.String())
	}
}
