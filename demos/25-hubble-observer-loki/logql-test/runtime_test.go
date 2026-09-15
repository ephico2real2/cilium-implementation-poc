package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/grafana/loki/v3/pkg/logql/syntax"
	"github.com/prometheus/prometheus/model/labels"
)

// dashboardPath: the fork's dashboard as the lab installs it (.tmp/hubble-observer-fork, chart-from-fork.sh), or DASHBOARD=<file>
func dashboardPath() string {
	if p := os.Getenv("DASHBOARD"); p != "" { return p }
	return "../../../.tmp/hubble-observer-fork/helm/hubble-observer/dashboard/cilium-hubble-flows.json"
}

// the log pipeline of a panel's metric query, run by Loki's own engine on synthetic Hubble JSON lines
func pipelineOf(t *testing.T, id int) func(line string) (labels.Labels, bool) {
	var d struct {
		Panels []struct {
			ID      int `json:"id"`
			Targets []struct{ Expr string `json:"expr"` } `json:"targets"`
		} `json:"panels"`
	}
	b, err := os.ReadFile(dashboardPath())
	if err != nil { t.Fatal(err) }
	if err := json.Unmarshal(b, &d); err != nil { t.Fatal(err) }
	vars := map[string]string{"$hubbleobservernamespace": "hubble-observer", "$searchregex": ".", "$excluderegex": "a^",
		"$logparser": "regexp `(?P<message>.+)` | line_format `{{.message}}` | json", "$sourcenamespace": ".*", "$destinationnamespace": ".*",
		"$direction": ".*", "$ipversion": ".*", "$sourcecluster": ".*", "$destinationcluster": ".*"}
	var expr string
	for _, p := range d.Panels { if p.ID == id { expr = p.Targets[0].Expr } }
	for k, v := range vars { expr = strings.ReplaceAll(expr, k, v) }
	// the log selector is what is inside count_over_time( … [ )
	start := strings.Index(expr, "{namespace"); end := strings.LastIndex(expr, "[")
	sel := strings.TrimSpace(expr[start:end])
	le, err := syntax.ParseLogSelector(sel, true)
	if err != nil { t.Fatalf("panel %d selector: %v\n%s", id, err, sel) }
	pl, err := le.Pipeline()
	if err != nil { t.Fatal(err) }
	sp := pl.ForStream(labels.FromStrings("namespace", "hubble-observer", "container", "hubble-observer"))
	return func(line string) (labels.Labels, bool) {
		_, res, ok := sp.Process(0, []byte(line), labels.EmptyLabels())
		if !ok { return labels.EmptyLabels(), false }
		return res.Labels(), true
	}
}

const (
	forwarded = `{"flow":{"verdict":"FORWARDED","traffic_direction":"INGRESS","IP":{"ipVersion":"IPv4"},"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
	l7drop    = `{"flow":{"verdict":"DROPPED","traffic_direction":"INGRESS","IP":{"ipVersion":"IPv4"},"l7":{"type":"REQUEST","http":{"method":"GET"}},"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
	defdeny   = `{"flow":{"verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","traffic_direction":"INGRESS","IP":{"ipVersion":"IPv4"},"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
	named     = `{"flow":{"verdict":"DROPPED","drop_reason_desc":"POLICY_DENY","traffic_direction":"EGRESS","IP":{"ipVersion":"IPv4"},"egress_denied_by":[{"name":"bank-cell-baseline","kind":"CiliumNetworkPolicy"}],"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
	unnamed   = `{"flow":{"verdict":"DROPPED","drop_reason_desc":"POLICY_DENY","traffic_direction":"INGRESS","IP":{"ipVersion":"IPv4"},"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
	other     = `{"flow":{"verdict":"DROPPED","drop_reason_desc":"SERVICE_BACKEND_NOT_FOUND","traffic_direction":"EGRESS","IP":{"ipVersion":"IPv4"},"source":{"namespace":"a"},"destination":{"namespace":"b"}}}`
)

func TestPanel15(t *testing.T) {
	run := pipelineOf(t, 15)
	want := map[string]string{forwarded: "", l7drop: "L7 denied by the proxy (REQUEST)", defdeny: "POLICY_DENIED", named: "POLICY_DENY", unnamed: "POLICY_DENY", other: "SERVICE_BACKEND_NOT_FOUND"}
	for line, w := range want {
		lbs, ok := run(line)
		got := ""; if ok { got = lbs.Get("drop_reason") }
		if (w == "") != !ok || got != w { t.Errorf("panel 15: want %q matched=%v, got %q matched=%v for %s", w, w != "", got, ok, line[:60]) }
	}
}

func TestPanel16(t *testing.T) {
	run := pipelineOf(t, 16)
	want := map[string]string{forwarded: "", l7drop: "", other: "", defdeny: "default deny (no matching allow)", named: "bank-cell-baseline", unnamed: "explicit deny (policy name unavailable)"}
	for line, w := range want {
		lbs, ok := run(line)
		got := ""; if ok { got = lbs.Get("denied_by") }
		if (w == "") != !ok || got != w { t.Errorf("panel 16: want %q matched=%v, got %q matched=%v for %s", w, w != "", got, ok, line[:60]) }
	}
}
