// shopctl — the shop platform's external Go client (enhancement 002 §3.3).
//
// One contract with the Python sibling: probe every path once; load N req/s for M seconds;
// report status and X-Served-By; never interpret the serving cluster. The client knows only --url.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultTimeout = 2 * time.Second
	probePathFmt   = "%-10s %-8s %s\n"
	loadPathFmt    = "%-8s %-6s %-6s %s\n"
)

var probePaths = []string{"/healthz", "/ready", "/orders"}

type config struct {
	cmd      string
	url      string
	cacert   string
	insecure bool
	timeout  time.Duration
	rate     int
	duration time.Duration
	path     string
}

// durationValue is the shared spelling of --timeout and --duration: a bare number is SECONDS
// (what the Python sibling and argparse take: "3", "0.5"), a Go duration keeps its unit ("3s",
// "500ms", "1m"). One flag type, one contract, so a runbook line works verbatim with either client.
type durationValue time.Duration

func parseDuration(s string) (time.Duration, error) {
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		if f < 0 {
			return 0, fmt.Errorf("negative duration %q", s)
		}
		return time.Duration(f * float64(time.Second)), nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("%q is neither seconds (3, 0.5) nor a duration (3s, 500ms, 1m)", s)
	}
	return d, nil
}

func (d *durationValue) String() string { return time.Duration(*d).String() }

func (d *durationValue) Set(s string) error {
	v, err := parseDuration(s)
	if err != nil {
		return err
	}
	*d = durationValue(v)
	return nil
}

func usage() {
	fmt.Fprintf(os.Stderr, `shopctl — probe or load an HTTPS door. The client knows only --url.

  shopctl probe --url URL [--cacert FILE] [--insecure|-k] [--timeout SECONDS|DURATION]
  shopctl load  --url URL --rate N --duration SECONDS|DURATION [--path PATH] [--cacert FILE] [--insecure|-k] [--timeout SECONDS|DURATION]

probe prints PATH STATUS X-SERVED-BY for /healthz, /ready, /orders.
load prints SECOND OK FAIL X-SERVED-BY per second, then latency_ms p50 p95 p99 max;
exit code is the number of seconds that saw any failure.
`)
}

func parseArgs(args []string) (*config, error) {
	if len(args) < 1 {
		return nil, errors.New("missing command (probe|load)")
	}
	cmd := args[0]
	if cmd != "probe" && cmd != "load" {
		return nil, fmt.Errorf("unknown command %q (want probe or load)", cmd)
	}
	fs := flag.NewFlagSet("shopctl "+cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	cfg := &config{cmd: cmd, timeout: defaultTimeout, path: "/healthz"}
	fs.StringVar(&cfg.url, "url", "", "base URL of the door (required)")
	fs.StringVar(&cfg.cacert, "cacert", "", "PEM file of the CA to trust")
	fs.BoolVar(&cfg.insecure, "insecure", false, "skip CA verification")
	fs.BoolVar(&cfg.insecure, "k", false, "skip CA verification (the operator's flag)")
	fs.Var((*durationValue)(&cfg.timeout), "timeout", "per-request timeout: seconds or a duration (default 2s)")
	if cmd == "load" {
		fs.IntVar(&cfg.rate, "rate", 0, "requests per second")
		fs.Var((*durationValue)(&cfg.duration), "duration", "how long to run: seconds or a duration")
		fs.StringVar(&cfg.path, "path", "/healthz", "path to hit (default /healthz)")
	}
	if err := fs.Parse(args[1:]); err != nil {
		return nil, err
	}
	if cfg.url == "" {
		return nil, errors.New("--url is required")
	}
	if cmd == "load" {
		if cfg.rate <= 0 {
			return nil, errors.New("--rate must be a positive integer")
		}
		if cfg.duration <= 0 {
			return nil, errors.New("--duration must be a positive duration")
		}
		if !strings.HasPrefix(cfg.path, "/") {
			cfg.path = "/" + cfg.path
		}
	}
	cfg.url = strings.TrimRight(cfg.url, "/")
	return cfg, nil
}

func newClient(cfg *config) (*http.Client, error) {
	tlsCfg := &tls.Config{}
	switch {
	case cfg.insecure:
		tlsCfg.InsecureSkipVerify = true
	case cfg.cacert != "":
		pem, err := os.ReadFile(cfg.cacert)
		if err != nil {
			return nil, fmt.Errorf("cacert: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("cacert %s: no certificates parsed", cfg.cacert)
		}
		tlsCfg.RootCAs = pool
	}
	return &http.Client{
		Timeout:   cfg.timeout,
		Transport: &http.Transport{TLSClientConfig: tlsCfg},
	}, nil
}

type hit struct {
	status  int
	served  string
	latency time.Duration
	err     error
}

func doHit(client *http.Client, url string) hit {
	start := time.Now()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return hit{err: err, latency: time.Since(start)}
	}
	resp, err := client.Do(req)
	lat := time.Since(start)
	if err != nil {
		return hit{err: err, latency: lat}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	return hit{status: resp.StatusCode, served: resp.Header.Get("X-Served-By"), latency: lat}
}

func joinServed(values []string) string {
	seen := map[string]struct{}{}
	var out []string
	for _, v := range values {
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	sort.Strings(out)
	if len(out) == 0 {
		return "-"
	}
	return strings.Join(out, ",")
}

type secondAgg struct {
	second int
	ok     int
	fail   int
	served []string
}

func aggregateSecond(second int, hits []hit) secondAgg {
	a := secondAgg{second: second}
	for _, h := range hits {
		if h.err == nil && h.status >= 200 && h.status < 300 {
			a.ok++
			a.served = append(a.served, h.served)
		} else {
			a.fail++
			if h.served != "" {
				a.served = append(a.served, h.served)
			}
		}
	}
	return a
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if p <= 0 {
		return sorted[0]
	}
	if p >= 100 {
		return sorted[len(sorted)-1]
	}
	idx := int((p / 100) * float64(len(sorted)-1))
	return sorted[idx]
}

func latencySummary(hits []hit) (p50, p95, p99, max float64) {
	ms := make([]float64, 0, len(hits))
	for _, h := range hits {
		v := float64(h.latency) / float64(time.Millisecond)
		ms = append(ms, v)
		if v > max {
			max = v
		}
	}
	sort.Float64s(ms)
	return percentile(ms, 50), percentile(ms, 95), percentile(ms, 99), max
}

func runProbe(w io.Writer, client *http.Client, base string) int {
	fmt.Fprintf(w, probePathFmt, "PATH", "STATUS", "X-SERVED-BY")
	fails := 0
	for _, p := range probePaths {
		h := doHit(client, base+p)
		status := "000"
		served := "-"
		if h.err == nil {
			status = fmt.Sprintf("%d", h.status)
			if h.served != "" {
				served = h.served
			}
			if h.status < 200 || h.status >= 300 {
				fails++
			}
		} else {
			fails++
		}
		fmt.Fprintf(w, probePathFmt, p, status, served)
	}
	return fails
}

func fireSecond(client *http.Client, url string, rate int) []hit {
	hits := make([]hit, rate)
	var wg sync.WaitGroup
	wg.Add(rate)
	for i := 0; i < rate; i++ {
		go func(i int) {
			defer wg.Done()
			hits[i] = doHit(client, url)
		}(i)
	}
	wg.Wait()
	return hits
}

func runLoad(w io.Writer, client *http.Client, cfg *config) int {
	url := cfg.url + cfg.path
	seconds := int(cfg.duration.Round(time.Second) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	fmt.Fprintf(w, loadPathFmt, "SECOND", "OK", "FAIL", "X-SERVED-BY")
	var all []hit
	failSeconds := 0
	for sec := 1; sec <= seconds; sec++ {
		start := time.Now()
		hits := fireSecond(client, url, cfg.rate)
		all = append(all, hits...)
		agg := aggregateSecond(sec, hits)
		fmt.Fprintf(w, loadPathFmt, fmt.Sprintf("%d", agg.second), fmt.Sprintf("%d", agg.ok), fmt.Sprintf("%d", agg.fail), joinServed(agg.served))
		if agg.fail > 0 {
			failSeconds++
		}
		if remain := time.Second - time.Since(start); remain > 0 && sec < seconds {
			time.Sleep(remain)
		}
	}
	p50, p95, p99, max := latencySummary(all)
	fmt.Fprintf(w, "latency_ms  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f\n", p50, p95, p99, max)
	return failSeconds
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help") {
		usage()
		os.Exit(0)
	}
	cfg, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "shopctl: %v\n", err)
		usage()
		os.Exit(2)
	}
	client, err := newClient(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "shopctl: %v\n", err)
		os.Exit(2)
	}
	switch cfg.cmd {
	case "probe":
		os.Exit(runProbe(os.Stdout, client, cfg.url))
	case "load":
		os.Exit(runLoad(os.Stdout, client, cfg))
	}
}
