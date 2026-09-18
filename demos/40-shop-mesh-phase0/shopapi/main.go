// shopapi — the shop platform's Go backend (enhancement 002 §3.2).
//
// GET /healthz → 200 ok (never touches the DB)
// GET /ready   → SELECT 1 against DB_URL (default postgres://shop:shop@db-service.poc.local:5432/shop?sslmode=disable)
// GET /orders  → SELECT id, item, amount_cents FROM orders ORDER BY id as JSON
//
// Every response carries X-Served-By (<CLUSTER>) and X-Pod (<hostname>). The table is created by
// phase 2's DB init; /orders and /ready return 503 with the error when the DB is unreachable.
// No Deployment in phase 0 — this image is built and loaded so demo 41 can run it.
//
// ONE pool. The *sql.DB is opened once in main (openDB) and shared by every request; a pool per
// request would open a fresh TCP+startup handshake per call and leak goroutines under load. The
// pool's connect timeout (connectTimeout) is what bounds a black-holed DB — the per-request context
// (requestTimeout) is the outer bound for the query itself. Identity headers are set by a
// middleware so ServeMux 404s carry them too.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"jsonview"
)

const (
	defaultDBURL   = "postgres://shop:shop@db-service.poc.local:5432/shop?sslmode=disable"
	connectTimeout = 1 * time.Second // TCP connect + startup handshake per new connection
	requestTimeout = 2 * time.Second // the whole /ready or /orders round trip
	maxOpenConns   = 8               // shopapi is a demo backend; the DB (phase 2) is one pod
)

func cluster() string {
	if c := os.Getenv("CLUSTER"); c != "" {
		return c
	}
	return "unknown"
}

func podName() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	return h
}

func dbURL() string {
	if u := os.Getenv("DB_URL"); u != "" {
		return u
	}
	return defaultDBURL
}

// openDB parses DB_URL once and builds the shared pool. A malformed URL fails here, at startup,
// with the parser's message — not on the first request.
func openDB() (*sql.DB, error) {
	cfg, err := pgx.ParseConfig(dbURL())
	if err != nil {
		return nil, fmt.Errorf("DB_URL: %w", err)
	}
	if cfg.ConnectTimeout == 0 { // a connect_timeout in the URL wins; otherwise the default above
		cfg.ConnectTimeout = connectTimeout
	}
	db := stdlib.OpenDB(*cfg)
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxOpenConns)
	db.SetConnMaxIdleTime(5 * time.Minute)
	return db, nil
}

type server struct {
	db *sql.DB
}

func identityMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Served-By", cluster())
		w.Header().Set("X-Pod", podName())
		next.ServeHTTP(w, r)
	})
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

func (s *server) pingDB(ctx context.Context) error {
	var one int
	return s.db.QueryRowContext(ctx, "SELECT 1").Scan(&one)
}

func (s *server) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	if err := s.pingDB(ctx); err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

type order struct {
	ID          int64  `json:"id"`
	Item        string `json:"item"`
	AmountCents int64  `json:"amount_cents"`
}

func (s *server) handleOrders(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	rows, err := s.db.QueryContext(ctx, "SELECT id, item, amount_cents FROM orders ORDER BY id")
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer rows.Close()
	out := []order{}
	for rows.Next() {
		var o order
		if err := rows.Scan(&o.ID, &o.Item, &o.AmountCents); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	body, err := json.Marshal(out)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	body = append(body, '\n')
	jsonview.Write(w, r, http.StatusOK, body, "shopapi")
}

func newMux(db *sql.DB) http.Handler {
	s := &server{db: db}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /ready", s.handleReady)
	mux.HandleFunc("GET /orders", s.handleOrders)
	return identityMiddleware(mux)
}

func main() {
	addr := ":8080"
	if a := os.Getenv("LISTEN"); a != "" {
		addr = a
	}
	db, err := openDB()
	if err != nil {
		log.Fatalf("shopapi: %v", err)
	}
	defer db.Close()
	log.Printf("shopapi cluster=%s pod=%s listening on %s", cluster(), podName(), addr)
	srv := &http.Server{
		Addr:              addr,
		Handler:           newMux(db),
		ReadHeaderTimeout: 5 * time.Second, // slowloris guard; the door in front is Envoy, but the pod is also reachable directly
	}
	log.Fatal(srv.ListenAndServe())
}
