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
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
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

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
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

func healthz(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
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
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("GET /accounts/{id}", func(w http.ResponseWriter, r *http.Request) {
		var owner string
		var bal int64
		err := db.QueryRowContext(r.Context(), `SELECT owner, balance_cents FROM accounts WHERE id=$1`, r.PathValue("id")).Scan(&owner, &bal)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, 404, map[string]any{"error": "no such account", "served_by": me("accounts")})
			return
		}
		if err != nil {
			writeJSON(w, 500, map[string]any{"error": err.Error(), "served_by": me("accounts")})
			return
		}
		writeJSON(w, 200, map[string]any{"account": r.PathValue("id"), "owner": owner, "balance_cents": bal, "served_by": me("accounts")})
	})
	// debit is the money-moving call: one UPDATE guarded by the balance, so two concurrent debits
	// cannot overdraw — the database is the arbiter, not the caller.
	mux.HandleFunc("POST /accounts/{id}/debit", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AmountCents int64  `json:"amount_cents"`
			Ref         string `json:"ref"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.AmountCents <= 0 {
			writeJSON(w, 400, map[string]any{"error": "amount_cents must be > 0", "served_by": me("accounts")})
			return
		}
		var bal int64
		err := db.QueryRowContext(r.Context(), `UPDATE accounts SET balance_cents = balance_cents - $2 WHERE id=$1 AND balance_cents >= $2 RETURNING balance_cents`, r.PathValue("id"), in.AmountCents).Scan(&bal)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, 409, map[string]any{"error": "insufficient funds or no such account", "served_by": me("accounts")})
			return
		}
		if err != nil {
			writeJSON(w, 500, map[string]any{"error": err.Error(), "served_by": me("accounts")})
			return
		}
		writeJSON(w, 200, map[string]any{"account": r.PathValue("id"), "debited_cents": in.AmountCents, "ref": in.Ref, "balance_cents": bal, "served_by": me("accounts")})
	})
	log.Printf("accounts: HTTP on %s, postgres ok", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
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
			writeJSON(w, 400, map[string]any{"error": "account, amount_cents>0 and key are required", "served_by": me("payments")})
			return
		}
		ctx := r.Context()
		// Idempotency: the key is claimed BEFORE money moves. A retry with the same key gets the
		// stored result and never debits twice — the property a card network actually needs.
		claimed, err := rdb.SetNX(ctx, "pay:"+in.Key, "pending", 24*time.Hour).Result()
		if err != nil {
			writeJSON(w, 503, map[string]any{"error": "redis: " + err.Error(), "served_by": me("payments")})
			return
		}
		if !claimed {
			prev, _ := rdb.Get(ctx, "pay:"+in.Key).Result()
			out := map[string]any{"replay": true, "served_by": me("payments")}
			_ = json.Unmarshal([]byte(prev), &out)
			out["replay"], out["served_by"] = true, me("payments")
			writeJSON(w, 200, out)
			return
		}
		up, code, err := call(ctx, "POST", accountsURL+"/accounts/"+in.Account+"/debit", map[string]any{"amount_cents": in.AmountCents, "ref": "card:" + in.Merchant})
		if err != nil {
			rdb.Del(ctx, "pay:"+in.Key) // release the key so a later retry can succeed
			if code == 0 {
				code = 502
			}
			writeJSON(w, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("payments")})
			return
		}
		rec := map[string]any{"key": in.Key, "account": in.Account, "amount_cents": in.AmountCents, "merchant": in.Merchant, "at": time.Now().UTC().Format(time.RFC3339), "served_by": me("payments"), "upstream": up}
		b, _ := json.Marshal(rec)
		rdb.Set(ctx, "pay:"+in.Key, b, 24*time.Hour)
		rdb.LPush(ctx, "payments:"+in.Account, b)
		rdb.LTrim(ctx, "payments:"+in.Account, 0, 49)
		writeJSON(w, 201, rec)
	})
	mux.HandleFunc("GET /payments/{account}", func(w http.ResponseWriter, r *http.Request) {
		items, err := rdb.LRange(r.Context(), "payments:"+r.PathValue("account"), 0, 19).Result()
		if err != nil {
			writeJSON(w, 503, map[string]any{"error": "redis: " + err.Error(), "served_by": me("payments")})
			return
		}
		list := make([]map[string]any, 0, len(items))
		for _, it := range items {
			m := map[string]any{}
			_ = json.Unmarshal([]byte(it), &m)
			list = append(list, m)
		}
		writeJSON(w, 200, map[string]any{"account": r.PathValue("account"), "payments": list, "served_by": me("payments")})
	})
	log.Printf("payments: HTTP on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
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
			writeJSON(w, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("api")})
			return
		}
		writeJSON(w, 200, map[string]any{"account": r.PathValue("id"), "balance_cents": up["balance_cents"], "owner": up["owner"], "served_by": me("api"), "upstream": up})
	})
	mux.HandleFunc("POST /api/pay", func(w http.ResponseWriter, r *http.Request) {
		in := map[string]any{}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			writeJSON(w, 400, map[string]any{"error": "bad json", "served_by": me("api")})
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
			writeJSON(w, code, map[string]any{"error": err.Error(), "upstream": up, "served_by": me("api")})
			return
		}
		writeJSON(w, code, map[string]any{"payment": up, "served_by": me("api")})
	})
	mux.HandleFunc("GET /api/statement/{id}", func(w http.ResponseWriter, r *http.Request) {
		bal, _, err1 := call(r.Context(), "GET", accountsURL+"/accounts/"+r.PathValue("id"), nil)
		pays, _, err2 := call(r.Context(), "GET", paymentsURL+"/payments/"+r.PathValue("id"), nil)
		out := map[string]any{"account": r.PathValue("id"), "served_by": me("api"), "balance": bal, "statement": pays}
		if err1 != nil || err2 != nil {
			out["errors"] = map[string]any{"accounts": errStr(err1), "payments": errStr(err2)}
			writeJSON(w, 502, out)
			return
		}
		writeJSON(w, 200, out)
	})
	log.Printf("api: HTTP on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
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
<form method="post" action="/pay">amount (cents) <input name="amount_cents" value="1250"> merchant <input name="merchant" value="coffee"> <button>pay by card</button></form>
<h2>recent card payments</h2>
<table><tr><th>at</th><th>merchant</th><th>cents</th><th>payments pod</th><th>debited by</th></tr>
{{range .PaymentsList}}<tr><td>{{.at}}</td><td>{{.merchant}}</td><td>{{.amount_cents}}</td><td>{{with .served_by}}{{.cluster}}/{{.pod}}{{end}}</td><td>{{with .upstream}}{{with .served_by}}{{.cluster}}/{{.pod}}{{end}}{{end}}</td></tr>{{end}}
</table></body></html>`))

// pageView is what the template renders: the statement, plus the cluster/pod of every hop.
type pageView struct {
	Account, Owner, Balance, Error string
	Web, API, Accounts, Payments   servedBy
	PaymentsList                   []map[string]any
}

func serveWeb(addr string) {
	apiURL := env("API_URL", "http://api.bank.svc.cluster.local")
	account := env("ACCOUNT", "chk-1001")
	mux := http.NewServeMux()
	healthz(mux)
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		v := pageView{Account: account, Web: me("web")}
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
	mux.HandleFunc("POST /pay", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var cents int64
		fmt.Sscanf(strings.TrimSpace(r.Form.Get("amount_cents")), "%d", &cents)
		_, _, _ = call(r.Context(), "POST", apiURL+"/api/pay", map[string]any{"account": account, "amount_cents": cents, "merchant": r.Form.Get("merchant"), "key": fmt.Sprintf("web-%d", time.Now().UnixNano())})
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	log.Printf("web: HTTP on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

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
