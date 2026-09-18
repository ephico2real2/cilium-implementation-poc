// shopapi — the shop platform's Go backend (enhancement 002 §3.2).
//
// GET /healthz → 200 ok
// GET /ready   → SELECT 1 against DB_URL (default postgres://shop:shop@db-service.poc.local:5432/shop?sslmode=disable)
// GET /orders  → SELECT id, item, amount_cents FROM orders ORDER BY id as JSON
//
// Every response carries X-Served-By (<CLUSTER>) and X-Pod (<hostname>). The table is created by
// phase 2's DB init; /orders and /ready return 503 with the error when the DB is unreachable.
// No Deployment in phase 0 — this image is built and loaded so demo 41 can run it.
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

	_ "github.com/jackc/pgx/v5/stdlib"
	"jsonview"
)

const defaultDBURL = "postgres://shop:shop@db-service.poc.local:5432/shop?sslmode=disable"

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

func withIdentity(w http.ResponseWriter) {
	w.Header().Set("X-Served-By", cluster())
	w.Header().Set("X-Pod", podName())
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	withIdentity(w)
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

func pingDB(ctx context.Context) error {
	db, err := sql.Open("pgx", dbURL())
	if err != nil {
		return err
	}
	defer db.Close()
	var one int
	return db.QueryRowContext(ctx, "SELECT 1").Scan(&one)
}

func handleReady(w http.ResponseWriter, r *http.Request) {
	withIdentity(w)
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := pingDB(ctx); err != nil {
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

func handleOrders(w http.ResponseWriter, r *http.Request) {
	withIdentity(w)
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", dbURL())
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer db.Close()
	rows, err := db.QueryContext(ctx, "SELECT id, item, amount_cents FROM orders ORDER BY id")
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer rows.Close()
	var out []order
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
	if out == nil {
		out = []order{}
	}
	body, err := json.Marshal(out)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	body = append(body, '\n')
	jsonview.Write(w, r, http.StatusOK, body, "shopapi")
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /ready", handleReady)
	mux.HandleFunc("GET /orders", handleOrders)
	return mux
}

func main() {
	addr := ":8080"
	if a := os.Getenv("LISTEN"); a != "" {
		addr = a
	}
	log.Printf("shopapi cluster=%s pod=%s listening on %s", cluster(), podName(), addr)
	log.Fatal(http.ListenAndServe(addr, newMux()))
}
