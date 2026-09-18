package main

import (
	"testing"
	"time"
)

// The Python sibling takes seconds as a number (--duration 3, --timeout 1). The Go client must
// accept the same spelling AND Go's unit spelling, or the two clients do not share one contract.
func TestDurationFlagsAcceptBareSecondsAndUnits(t *testing.T) {
	cases := map[string]time.Duration{"3": 3 * time.Second, "3s": 3 * time.Second, "0.5": 500 * time.Millisecond, "500ms": 500 * time.Millisecond, "1m": time.Minute}
	for in, want := range cases {
		cfg, err := parseArgs([]string{"load", "--url", "https://x", "--rate", "1", "--duration", in, "--timeout", in})
		if err != nil {
			t.Fatalf("--duration %s: %v", in, err)
		}
		if cfg.duration != want || cfg.timeout != want {
			t.Fatalf("--duration/--timeout %s parsed as %v/%v, want %v", in, cfg.duration, cfg.timeout, want)
		}
	}
	if _, err := parseArgs([]string{"probe", "--url", "https://x", "--timeout", "soon"}); err == nil {
		t.Fatal("want an error for a non-numeric, non-duration --timeout")
	}
}

// Same data, same percentile numbers as the Python sibling (nearest lower rank, no interpolation).
func TestLatencySummaryNearestRank(t *testing.T) {
	var hs []hit
	for i := 1; i <= 10; i++ {
		hs = append(hs, hit{latency: time.Duration(i) * time.Millisecond})
	}
	p50, p95, p99, max := latencySummary(hs)
	if p50 != 5 || p95 != 9 || p99 != 9 || max != 10 {
		t.Fatalf("got %.2f %.2f %.2f %.2f, want 5 9 9 10", p50, p95, p99, max)
	}
}
