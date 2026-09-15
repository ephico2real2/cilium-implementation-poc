package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/grafana/loki/v3/pkg/logql/syntax"
)

func logparserOf() string { // the dashboard's own logparser variable, so the parse runs the parser the panels run
	var d struct{ Templating struct{ List []struct{ Name, Query string } } }
	b, _ := os.ReadFile(os.Args[1]); json.Unmarshal(b, &d)
	for _, v := range d.Templating.List { if v.Name == "logparser" { return v.Query } }
	return "json"
}

func main() {
	var d struct {
		Panels []struct {
			ID      int    `json:"id"`
			Title   string `json:"title"`
			Targets []struct{ Expr string `json:"expr"` } `json:"targets"`
		} `json:"panels"`
	}
	b, _ := os.ReadFile(os.Args[1])
	if err := json.Unmarshal(b, &d); err != nil { panic(err) }
	vars := map[string]string{"$hubbleobservernamespace": "hubble-observer", "$container": "hubble-observer", "$searchregex": ".", "$excluderegex": "a^",
		"$logparser": logparserOf(), "$sourcenamespace": ".*", "$destinationnamespace": ".*",
		"$direction": ".*", "$ipversion": ".*", "$sourcecluster": ".*", "$destinationcluster": ".*", "$__range": "30m", "$__auto": "1m", "$__interval": "1m"}
	bad := 0
	for _, p := range d.Panels {
		for _, t := range p.Targets {
			e := t.Expr
			for k, v := range vars { e = strings.ReplaceAll(e, k, v) }
			if _, err := syntax.ParseExpr(e); err != nil { bad++; fmt.Printf("panel %d %q: PARSE ERROR: %v\n", p.ID, p.Title, err) } else { fmt.Printf("panel %d %q: ok\n", p.ID, p.Title) }
		}
	}
	if bad > 0 { os.Exit(1) }
}
