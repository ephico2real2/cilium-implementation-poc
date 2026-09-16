// bankdemo — one binary, four roles, selected with -mode. One image for the whole bank so the
// ClusterMesh demo has exactly one moving part per cluster: which roles run where.
//
//	-mode web       online banking page (HTML)            -> poc1, behind the Gateway
//	-mode api       aggregator the page talks to          -> poc1
//	-mode payments  card payments, idempotent via redis   -> BOTH clusters (a global, shared service)
//	-mode accounts  checking accounts, system of record   -> poc2 only, backed by Postgres on a PVC
//
// Every JSON response carries "served_by": {cluster, pod, node}, and every upstream call's answer
// is embedded as "upstream", so a single response shows the whole cross-cluster path. That is the
// evidence the demo is built on: nothing is inferred from logs.
package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

// ---- shared -----------------------------------------------------------------------------------

type servedBy struct {
	Cluster string `json:"cluster"`
	Pod     string `json:"pod"`
	Node    string `json:"node"`
	Role    string `json:"role"`
}

func me(role string) servedBy {
	return servedBy{Cluster: env("CLUSTER", "unknown"), Pod: env("POD_NAME", "unknown"), Node: env("NODE_NAME", "unknown"), Role: role}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// wantsHTML is true when Accept lists text/html and does not list application/json before it.
// q-values and parameters are ignored; the first of the two media types that appears decides.
func wantsHTML(r *http.Request) bool {
	htmlIdx, jsonIdx := -1, -1
	for i, raw := range strings.Split(r.Header.Get("Accept"), ",") {
		media := strings.TrimSpace(raw)
		if j := strings.IndexByte(media, ';'); j >= 0 {
			media = strings.TrimSpace(media[:j])
		}
		switch media {
		case "text/html":
			if htmlIdx < 0 {
				htmlIdx = i
			}
		case "application/json":
			if jsonIdx < 0 {
				jsonIdx = i
			}
		}
	}
	if htmlIdx < 0 {
		return false
	}
	if jsonIdx >= 0 && jsonIdx < htmlIdx {
		return false
	}
	return true
}

func jsonTitle(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return "bank"
	}
	switch sb := m["served_by"].(type) {
	case servedBy:
		if sb.Role != "" {
			return sb.Role
		}
	case map[string]any:
		if role, _ := sb["role"].(string); role != "" {
			return role
		}
	}
	return "bank"
}

var (
	jsonHTMLKeyRe  = regexp.MustCompile(`^(\s*)(&#34;[^&]*?&#34;|"[^"]*")(:)`)
	jsonHTMLStrRe  = regexp.MustCompile(`&#34;.*?&#34;|"[^"]*"`)
	jsonHTMLBoolRe = regexp.MustCompile(`true|false|null`)
	jsonHTMLNumRe  = regexp.MustCompile(`-?\d+(\.\d+)?([eE][-+]?\d+)?`)
)

func colorJSON(pretty string) string {
	wrap := func(s string, re *regexp.Regexp, class string) (string, bool) {
		loc := re.FindStringIndex(s)
		if loc == nil {
			return s, false
		}
		return s[:loc[0]] + `<span class="` + class + `">` + s[loc[0]:loc[1]] + `</span>` + s[loc[1]:], true
	}
	var b strings.Builder
	for i, line := range strings.Split(pretty, "\n") {
		if i > 0 {
			b.WriteByte('\n')
		}
		esc := html.EscapeString(line)
		m := jsonHTMLKeyRe.FindStringSubmatchIndex(esc)
		if m == nil {
			b.WriteString(esc)
			continue
		}
		b.WriteString(esc[m[2]:m[3]])
		b.WriteString(`<span class="k">`)
		b.WriteString(esc[m[4]:m[5]])
		b.WriteString(`</span>`)
		b.WriteString(esc[m[6]:m[7]])
		rest := esc[m[1]:]
		if r, ok := wrap(rest, jsonHTMLStrRe, "s"); ok {
			b.WriteString(r)
			continue
		}
		if r, ok := wrap(rest, jsonHTMLBoolRe, "b"); ok {
			b.WriteString(r)
			continue
		}
		if r, ok := wrap(rest, jsonHTMLNumRe, "n"); ok {
			b.WriteString(r)
			continue
		}
		b.WriteString(rest)
	}
	return b.String()
}

func writeJSONHTML(w http.ResponseWriter, code int, compact []byte, title, method, path string) {
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, compact, "", "  "); err != nil {
		pretty.Reset()
		pretty.Write(compact)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	fmt.Fprintf(w, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<style>
body{background:#dde3ea;margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#2a3441}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 24px;background:#3a4a5c;border-bottom:1px solid #2f3d4d;color:#e6ebf0}
header .name{font-weight:600;font-size:15px}
header .req{color:#b9c4d0;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
main{max-width:880px;margin:24px auto;padding:0 16px}
.card{background:#faf8f4;border:1px solid #c5ccd5;border-radius:8px;box-shadow:0 1px 3px rgba(27,31,36,.06)}
pre{margin:0;padding:18px 20px;font:13.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#2a3441;white-space:pre-wrap;word-break:break-word;overflow-x:hidden}
.k{color:#2f5d8a}.s{color:#5c7a4a}.n,.b{color:#8a5a86}
.note{color:#5b6875;font-size:12.5px}
</style>
</head>
<body>
<header><span class="name">%s</span><span class="req">%s %s</span></header>
<main>
<div class="card"><pre>%s</pre></div>
<p class="note">Browsers get this page (Accept: text/html); curl and scripts get the same JSON, compact.</p>
</main>
</body>
</html>
`, html.EscapeString(title), html.EscapeString(title), html.EscapeString(method), html.EscapeString(path), colorJSON(pretty.String()))
}

func writeJSON(w http.ResponseWriter, r *http.Request, code int, v any) {
	b, _ := json.Marshal(v)
	b = append(b, '\n')
	if wantsHTML(r) {
			writeJSONHTML(w, code, b, jsonTitle(v), r.Method, r.URL.Path)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(b)
}

// One TCP connection per request, on purpose. Go's default client keeps connections alive, so a
// pooled connection to a Service pins EVERY request to whichever backend accepted the first one —
// the first run of this demo sent 40/40 payments to a single cluster and called it "active-active".
// For a demo whose point is to SHOW load balancing, each request must be a new connection; a real
// service would keep its pool and get the same distribution across many clients, not within one.
var httpClient = &http.Client{Timeout: 4 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}

// call does an upstream request and returns the decoded body; a non-2xx is an error carrying the
// upstream body so the caller can surface it (a 409 "insufficient funds" must reach the page).
func call(ctx context.Context, method, url string, body any) (map[string]any, int, error) {
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rdr)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode/100 != 2 {
		return out, resp.StatusCode, fmt.Errorf("%s %s -> %d", method, url, resp.StatusCode)
	}
	return out, resp.StatusCode, nil
}

// serve runs the HTTP server with a GRACEFUL shutdown. On SIGTERM (a scale-down, a rollout) it
// keeps serving for a short grace period so the cluster can remove this pod's endpoint from the
// service maps first, then stops accepting and lets in-flight requests finish. Without this, the
// first failover run answered one request with 502 at the exact second of the scale-down: the
// pod died with a connection open. Kubernetes removes the endpoint asynchronously; the app has
// to outlive that removal by a moment. terminationGracePeriodSeconds in the manifests covers it.
func serve(role, addr string, mux *http.ServeMux) {
	srv := &http.Server{Addr: addr, Handler: mux}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		// Fail readiness FIRST so the endpoint is withdrawn while we still finish what is in flight.
		// Without this a draining pod stays Ready for the whole grace period and keeps receiving NEW
		// requests — during a config repoint (demo 15 Part 8, case 3) an old pod still wired to the
		// dead primary answered one payment with 500 after "rollout status" had reported success.
		draining.Store(true)
		log.Printf("%s: SIGTERM — readiness now 503; serving in-flight for %s while the endpoint is withdrawn, then draining", role, drainDelay)
		time.Sleep(drainDelay)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
	log.Printf("%s: HTTP on %s", role, addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	log.Printf("%s: stopped", role)
}

const drainDelay = 4 * time.Second

var draining atomic.Bool

func healthz(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		if draining.Load() {
			http.Error(w, "draining", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ok")
	})
}

// ---- accounts: the system of record (Postgres) ---------------------------------------------------

func serveAccounts(addr string) {
	dsn := env("PG_DSN", "postgres://bank:bank@postgres.bank.svc.cluster.local:5432/bank?sslmode=disable")
	var db *sql.DB
	var err error
	// Postgres may come up after us (same StatefulSet ordering is not guaranteed across a PVC bind);
	// retry rather than crash-loop, and say so.
	for i := 1; i <= 30; i++ {
		db, err = sql.Open("pgx", dsn)
		if err == nil {
			err = db.PingContext(context.Background())
		}
		if err == nil {
			break
		}
		log.Printf("accounts: postgres not ready (%v), retry %d/30", err, i)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("accounts: postgres unreachable: %v", err)
	}
	const schema = `CREATE TABLE IF NOT EXISTS accounts (id text PRIMARY KEY, owner text NOT NULL, balance_cents bigint NOT NULL CHECK (balance_cents >= 0));
INSERT INTO accounts (id, owner, balance_cents) VALUES ('chk-1001','Ada Lovelace',250000), ('chk-1002','Grace Hopper',120000) ON CONFLICT (id) DO NOTHING;`
	if _, err := db.Exec(schema); err != nil {
		log.Fatalf("accounts: schema: %v", err)
	}
	// The hot standby (demo 15 Part 8): a second connection pool, used for READS ONLY and only when
	// the primary does not answer. Writes never go there — a standby is read-only until promoted,
	// and promotion is an operator's decision (the runbook), not something a request should trigger.
	var standby *sql.DB
	if dsn := os.Getenv("PG_STANDBY_DSN"); dsn != "" {
		if standby, err = sql.Open("pgx", dsn); err != nil {
			log.Printf("accounts: standby DSN rejected: %v", err)
			standby = nil
		} else {
			log.Printf("accounts: read fallback to standby configured")
		}
	}
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("GET /accounts/{id}", func(w http.ResponseWriter, r *http.Request) {
		var owner string
		var bal int64
		source := "primary"
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		err := db.QueryRowContext(ctx, `SELECT owner, balance_cents FROM accounts WHERE id=$1`, r.PathValue("id")).Scan(&owner, &bal)
		if err != nil && !errors.Is(err, sql.ErrNoRows) && standby != nil {
			log.Printf("accounts: primary read failed (%v) — trying the standby", err)
			source = "standby"
			ctx2, cancel2 := context.WithTimeout(r.Context(), 2*time.Second)
			defer cancel2()
			err = standby.QueryRowContext(ctx2, `SELECT owner, balance_cents FROM accounts WHERE id=$1`, r.PathValue("id")).Scan(&owner, &bal)
		}
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, r, 404, map[string]any{"error": "no such account", "served_by": me("accounts")})
			return
		}
		if err != nil {
			writeJSON(w, r, 503, map[string]any{"error": err.Error(), "served_by": me("accounts"), "db": source})
			return
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("id"), "owner": owner, "balance_cents": bal, "served_by": me("accounts"), "db": source})
	})
	// debit is the money-moving call: one UPDATE guarded by the balance, so two concurrent debits
	// cannot overdraw — the database is the arbiter, not the caller.
	mux.HandleFunc("POST /accounts/{id}/debit", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AmountCents int64  `json:"amount_cents"`
			Ref         string `json:"ref"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.AmountCents <= 0 {
			writeJSON(w, r, 400, map[string]any{"error": "amount_cents must be > 0", "served_by": me("accounts")})
			return
		}
		var bal int64
		err := db.QueryRowContext(r.Context(), `UPDATE accounts SET balance_cents = balance_cents - $2 WHERE id=$1 AND balance_cents >= $2 RETURNING balance_cents`, r.PathValue("id"), in.AmountCents).Scan(&bal)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, r, 409, map[string]any{"error": "insufficient funds or no such account", "served_by": me("accounts")})
			return
		}
		if err != nil {
			writeJSON(w, r, 500, map[string]any{"error": err.Error(), "served_by": me("accounts")})
			return
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("id"), "debited_cents": in.AmountCents, "ref": in.Ref, "balance_cents": bal, "served_by": me("accounts")})
	})
	mux.HandleFunc("POST /accounts/{id}/credit", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AmountCents int64  `json:"amount_cents"`
			Ref         string `json:"ref"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.AmountCents <= 0 {
			writeJSON(w, r, 400, map[string]any{"error": "amount_cents must be > 0", "served_by": me("accounts")})
			return
		}
		var bal int64
		err := db.QueryRowContext(r.Context(), `UPDATE accounts SET balance_cents = balance_cents + $2 WHERE id=$1 RETURNING balance_cents`, r.PathValue("id"), in.AmountCents).Scan(&bal)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, r, 404, map[string]any{"error": "no such account", "served_by": me("accounts")})
			return
		}
		if err != nil {
			writeJSON(w, r, 500, map[string]any{"error": err.Error(), "served_by": me("accounts")})
			return
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("id"), "credited_cents": in.AmountCents, "ref": in.Ref, "balance_cents": bal, "served_by": me("accounts")})
	})
	serve("accounts", addr, mux)
}

// ---- payments: card payments, idempotent, state in redis -------------------------------------------

func servePayments(addr string) {
	rdb := redis.NewClient(&redis.Options{Addr: env("REDIS_ADDR", "redis.bank.svc.cluster.local:6379"), DialTimeout: 3 * time.Second, ReadTimeout: 3 * time.Second})
	accountsURL := env("ACCOUNTS_URL", "http://accounts.bank.svc.cluster.local")
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("POST /payments", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Account     string `json:"account"`
			AmountCents int64  `json:"amount_cents"`
			Merchant    string `json:"merchant"`
			Key         string `json:"key"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Account == "" || in.AmountCents <= 0 || in.Key == "" {
			writeJSON(w, r, 400, map[string]any{"error": "account, amount_cents>0 and key are required", "served_by": me("payments")})
			return
		}
		ctx := r.Context()
		// Idempotency: the key is claimed BEFORE money moves. A retry with the same key gets the
		// stored result and never debits twice — the property a card network actually needs.
		claimed, err := rdb.SetNX(ctx, "pay:"+in.Key, "pending", 24*time.Hour).Result()
		if err != nil {
			writeJSON(w, r, 503, map[string]any{"error": "redis: " + err.Error(), "served_by": me("payments")})
			return
		}
		if !claimed {
			prev, _ := rdb.Get(ctx, "pay:"+in.Key).Result()
			out := map[string]any{"replay": true, "served_by": me("payments")}
			_ = json.Unmarshal([]byte(prev), &out)
			out["replay"], out["served_by"] = true, me("payments")
			writeJSON(w, r, 200, out)
			return
		}
		up, code, err := call(ctx, "POST", accountsURL+"/accounts/"+in.Account+"/debit", map[string]any{"amount_cents": in.AmountCents, "ref": "card:" + in.Merchant})
		if err != nil {
			rdb.Del(ctx, "pay:"+in.Key) // release the key so a later retry can succeed
			if code == 0 {
				code = 502
			}
			writeJSON(w, r, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("payments")})
			return
		}
		rec := map[string]any{"key": in.Key, "account": in.Account, "amount_cents": in.AmountCents, "merchant": in.Merchant, "at": time.Now().UTC().Format(time.RFC3339), "served_by": me("payments"), "upstream": up}
		b, _ := json.Marshal(rec)
		rdb.Set(ctx, "pay:"+in.Key, b, 24*time.Hour)
		rdb.LPush(ctx, "payments:"+in.Account, b)
		rdb.LTrim(ctx, "payments:"+in.Account, 0, 49)
		writeJSON(w, r, 201, rec)
	})
	mux.HandleFunc("GET /payments/{account}", func(w http.ResponseWriter, r *http.Request) {
		items, err := rdb.LRange(r.Context(), "payments:"+r.PathValue("account"), 0, 19).Result()
		if err != nil {
			writeJSON(w, r, 503, map[string]any{"error": "redis: " + err.Error(), "served_by": me("payments")})
			return
		}
		list := make([]map[string]any, 0, len(items))
		for _, it := range items {
			m := map[string]any{}
			_ = json.Unmarshal([]byte(it), &m)
			list = append(list, m)
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("account"), "payments": list, "served_by": me("payments")})
	})
	serve("payments", addr, mux)
}

// ---- api: the aggregator the page talks to ----------------------------------------------------------

func serveAPI(addr string) {
	accountsURL := env("ACCOUNTS_URL", "http://accounts.bank.svc.cluster.local")
	paymentsURL := env("PAYMENTS_URL", "http://payments.bank.svc.cluster.local")
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("GET /api/balance/{id}", func(w http.ResponseWriter, r *http.Request) {
		up, code, err := call(r.Context(), "GET", accountsURL+"/accounts/"+r.PathValue("id"), nil)
		if err != nil {
			if code == 0 {
				code = 502
			}
			writeJSON(w, r, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("api")})
			return
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("id"), "balance_cents": up["balance_cents"], "owner": up["owner"], "served_by": me("api"), "upstream": up})
	})
	mux.HandleFunc("POST /api/pay", func(w http.ResponseWriter, r *http.Request) {
		in := map[string]any{}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			writeJSON(w, r, 400, map[string]any{"error": "bad json", "served_by": me("api")})
			return
		}
		if k, _ := in["key"].(string); k == "" {
			in["key"] = fmt.Sprintf("api-%d", time.Now().UnixNano())
		}
		up, code, err := call(r.Context(), "POST", paymentsURL+"/payments", in)
		if err != nil {
			if code == 0 {
				code = 502
			}
			writeJSON(w, r, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("api")})
			return
		}
		writeJSON(w, r, code, map[string]any{"payment": up, "served_by": me("api")})
	})
	mux.HandleFunc("GET /api/statement/{id}", func(w http.ResponseWriter, r *http.Request) {
		bal, _, err1 := call(r.Context(), "GET", accountsURL+"/accounts/"+r.PathValue("id"), nil)
		pays, _, err2 := call(r.Context(), "GET", paymentsURL+"/payments/"+r.PathValue("id"), nil)
		out := map[string]any{"account": r.PathValue("id"), "served_by": me("api"), "balance": bal, "statement": pays}
		if err1 != nil || err2 != nil {
			out["errors"] = map[string]any{"accounts": errStr(err1), "payments": errStr(err2)}
			writeJSON(w, r, 502, out)
			return
		}
		writeJSON(w, r, 200, out)
	})
	// A deposit, for the exercise script to top an account up; the demo's only way to add money.
	mux.HandleFunc("POST /api/credit/{id}", func(w http.ResponseWriter, r *http.Request) {
		in := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&in)
		up, code, err := call(r.Context(), "POST", accountsURL+"/accounts/"+r.PathValue("id")+"/credit", map[string]any{"amount_cents": in["amount_cents"], "ref": "deposit"})
		if err != nil {
			if code == 0 {
				code = 502
			}
			writeJSON(w, r, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("api")})
			return
		}
		writeJSON(w, r, 200, map[string]any{"account": r.PathValue("id"), "balance_cents": up["balance_cents"], "served_by": me("api"), "upstream": up})
	})
	serve("api", addr, mux)
}

func errStr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// ---- web: the online banking page --------------------------------------------------------------------

var page = template.Must(template.New("p").Parse(`<!doctype html><html><head><meta charset="utf-8"><title>poc bank</title>
<style>body{font-family:system-ui;margin:2rem;max-width:56rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}code{background:#f3f3f3;padding:0 .2rem}.path{color:#555;font-size:.9rem}</style></head><body>
<h1>poc bank — account {{.Account}}</h1>
{{if .Error}}<p style="color:#b00">error: {{.Error}}</p>{{end}}
<p><b>{{.Owner}}</b> — balance <b>{{.Balance}}</b></p>
<p class="path">this page: <code>{{.Web.Cluster}}/{{.Web.Pod}}</code> → api: <code>{{.API.Cluster}}/{{.API.Pod}}</code> → accounts: <code>{{.Accounts.Cluster}}/{{.Accounts.Pod}}</code> · payments: <code>{{.Payments.Cluster}}/{{.Payments.Pod}}</code></p>
{{if .Flash}}<p style="color:{{if .FlashErr}}#b00{{else}}#070{{end}}"><b>{{.Flash}}</b></p>{{end}}
<form method="post" action="/pay">amount (USD) <input name="amount" value="{{.Amount}}" placeholder="12.50" size="8"> merchant <input name="merchant" value="{{.Merchant}}" placeholder="e.g. grocery" required> <button>pay by card</button></form>
<h2>recent card payments</h2>
<table><tr><th>at</th><th>merchant</th><th>cents</th><th>payments pod</th><th>debited by</th></tr>
{{range .PaymentsList}}<tr><td>{{.at}}</td><td>{{.merchant}}</td><td>{{.amount_cents}}</td><td>{{with .served_by}}{{.cluster}}/{{.pod}}{{end}}</td><td>{{with .upstream}}{{with .served_by}}{{.cluster}}/{{.pod}}{{end}}{{end}}</td></tr>{{end}}
</table></body></html>`))

// pageView is what the template renders: the statement, plus the cluster/pod of every hop.
type pageView struct {
	Account, Owner, Balance, Error string
	Web, API, Accounts, Payments   servedBy
	PaymentsList                   []map[string]any
	Flash, Amount, Merchant        string // what the last POST /pay did, and the form's last input
	FlashErr                       bool
}

// parseUSD turns what a person types into cents: "12.50", "$12.50", "1,250", "12" (dollars).
// The first version read the box as raw cents with Sscanf("%d"), so "12.50" charged 12 cents,
// "1,250" charged 1 cent, and "abc" charged nothing and said nothing.
func parseUSD(in string) (int64, error) {
	t := strings.NewReplacer("$", "", ",", "", " ", "").Replace(strings.TrimSpace(in))
	if t == "" {
		return 0, errors.New("amount is empty")
	}
	var dollars, cents int64
	parts := strings.SplitN(t, ".", 2)
	if _, err := fmt.Sscanf(parts[0], "%d", &dollars); err != nil && parts[0] != "" {
		return 0, fmt.Errorf("amount %q is not a number", in)
	}
	if len(parts) == 2 {
		frac := parts[1]
		if len(frac) > 2 || strings.Trim(frac, "0123456789") != "" {
			return 0, fmt.Errorf("amount %q: use at most two decimals", in)
		}
		for len(frac) < 2 {
			frac += "0"
		}
		fmt.Sscanf(frac, "%d", &cents)
	}
	total := dollars*100 + cents
	if total <= 0 {
		return 0, fmt.Errorf("amount %q must be more than $0.00", in)
	}
	return total, nil
}

func serveWeb(addr string) {
	apiURL := env("API_URL", "http://api.bank.svc.cluster.local")
	account := env("ACCOUNT", "chk-1001")
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		v := pageView{Account: account, Web: me("web"), Flash: q.Get("flash"), FlashErr: q.Get("err") == "1", Amount: q.Get("amount"), Merchant: q.Get("merchant")}
		st, _, err := call(r.Context(), "GET", apiURL+"/api/statement/"+account, nil)
		if err != nil {
			v.Error = err.Error()
		}
		if sb, ok := st["served_by"].(map[string]any); ok {
			v.API = toServed(sb)
		}
		if bal, ok := st["balance"].(map[string]any); ok {
			v.Owner, _ = bal["owner"].(string)
			v.Balance = fmt.Sprintf("%.2f", num(bal["balance_cents"])/100)
			if sb, ok := bal["served_by"].(map[string]any); ok {
				v.Accounts = toServed(sb)
			}
		}
		if p, ok := st["statement"].(map[string]any); ok {
			if sb, ok := p["served_by"].(map[string]any); ok {
				v.Payments = toServed(sb)
			}
			if list, ok := p["payments"].([]any); ok {
				for _, it := range list {
					if m, ok := it.(map[string]any); ok {
						v.PaymentsList = append(v.PaymentsList, m)
					}
				}
			}
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = page.Execute(w, v)
	})
	// POST /pay always redirects back to the page, carrying the outcome in the query string so the
	// page can SAY what happened — the first version swallowed every error and redirected silently.
	mux.HandleFunc("POST /pay", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		amount, merchant := strings.TrimSpace(r.Form.Get("amount")), strings.TrimSpace(r.Form.Get("merchant"))
		back := func(flash string, isErr bool) {
			u := "/?flash=" + urlQuery(flash) + "&amount=" + urlQuery(amount) + "&merchant=" + urlQuery(merchant)
			if isErr {
				u += "&err=1"
			}
			http.Redirect(w, r, u, http.StatusSeeOther)
		}
		cents, err := parseUSD(amount)
		if err != nil {
			log.Printf("web: POST /pay rejected: %v (merchant=%q)", err, merchant)
			back(err.Error(), true)
			return
		}
		if merchant == "" {
			back("merchant is required", true)
			return
		}
		key := fmt.Sprintf("web-%d", time.Now().UnixNano())
		up, code, err := call(r.Context(), "POST", apiURL+"/api/pay", map[string]any{"account": account, "amount_cents": cents, "merchant": merchant, "key": key})
		if err != nil {
			msg := fmt.Sprintf("payment failed (%d)", code)
			if p, ok := up["upstream"].(map[string]any); ok {
				if e, ok := p["error"].(string); ok {
					msg += ": " + e
				}
			} else if e, ok := up["error"].(string); ok {
				msg += ": " + e
			}
			log.Printf("web: POST /pay %s %d cents -> %s", merchant, cents, msg)
			back(msg, true)
			return
		}
		pay, _ := up["payment"].(map[string]any)
		by, _ := pay["served_by"].(map[string]any)
		upst, _ := pay["upstream"].(map[string]any)
		dby, _ := upst["served_by"].(map[string]any)
		flash := fmt.Sprintf("paid $%d.%02d to %s — payments %v/%v, debited by %v/%v, balance now $%.2f", cents/100, cents%100, merchant, by["cluster"], by["pod"], dby["cluster"], dby["pod"], num(upst["balance_cents"])/100)
		log.Printf("web: POST /pay %s %d cents -> %d via payments %v, accounts %v", merchant, cents, code, by["cluster"], dby["cluster"])
		back(flash, false)
	})
	serve("web", addr, mux)
}

func urlQuery(v string) string { return url.QueryEscape(v) }

func toServed(m map[string]any) servedBy {
	s := servedBy{}
	s.Cluster, _ = m["cluster"].(string)
	s.Pod, _ = m["pod"].(string)
	s.Node, _ = m["node"].(string)
	s.Role, _ = m["role"].(string)
	return s
}

func num(v any) float64 {
	f, _ := v.(float64)
	return f
}

func main() {
	mode := flag.String("mode", "web", "web | api | payments | accounts")
	addr := flag.String("addr", ":8080", "listen address")
	flag.Parse()
	switch *mode {
	case "web":
		serveWeb(*addr)
	case "api":
		serveAPI(*addr)
	case "payments":
		servePayments(*addr)
	case "accounts":
		serveAccounts(*addr)
	default:
		log.Fatalf("unknown -mode %q", *mode)
	}
}
