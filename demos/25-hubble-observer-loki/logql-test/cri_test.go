package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/grafana/loki/v3/pkg/logql/syntax"
	"github.com/prometheus/prometheus/model/labels"
)

// the dashboard's logparser variable on a pure JSON line and on a CRI record (containerd's log file line shape)
func TestLogParserPureAndCRI(t *testing.T) {
	var d struct{ Templating struct{ List []struct{ Name, Query string } } }
	b, _ := os.ReadFile(dashboardPath())
	if err := json.Unmarshal(b, &d); err != nil { t.Fatal(err) }
	var lp string
	for _, v := range d.Templating.List { if v.Name == "logparser" { lp = v.Query } }
	sel := `{namespace="hubble-observer"} | ` + lp + ` | flow_verdict="DROPPED"`
	le, err := syntax.ParseLogSelector(sel, true)
	if err != nil { t.Fatalf("%v\n%s", err, sel) }
	pl, _ := le.Pipeline(); sp := pl.ForStream(labels.FromStrings("namespace", "hubble-observer"))
	pure := `{"flow":{"verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","source":{"namespace":"a"}}}`
	cri := `2026-09-15T16:20:01.123456789Z stdout F ` + pure
	for name, line := range map[string]string{"pure JSON": pure, "CRI full record": cri} {
		_, res, ok := sp.Process(0, []byte(line), labels.EmptyLabels())
		if !ok || res.Labels().Get("flow_drop_reason_desc") != "POLICY_DENIED" || strings.Contains(res.Labels().String(), "__error__") {
			t.Errorf("%s: matched=%v labels=%s", name, ok, res.Labels().String())
		}
	}
}
