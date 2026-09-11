// A single binary that can play three roles, selected with -mode. One image, three workloads,
// three Gateway API route types.
//
//	-mode http   plain HTTP server           -> HTTPRoute
//	-mode grpc   gRPC server                 -> GRPCRoute
//	-mode tcp    line-echo TCP server        -> TCPRoute
//
// WHY ONE BINARY INSTEAD OF THREE. Three images means three builds, three pushes and three
// `kind load` steps on a laptop that just ran out of disk. One static binary keeps the image at a
// few megabytes and makes the three deployments differ by a single argument, which also makes the
// comparison between route types the only variable.
//
// WHY THE gRPC SIDE USES THE HEALTH SERVICE. A normal gRPC demo needs a .proto file, protoc, and
// generated stubs checked in or generated at build time. grpc-go already ships the standard
// Health service (grpc.health.v1.Health), so we get a REAL gRPC service -- real HTTP/2, real
// protobuf framing -- with no codegen at all, and it is callable by grpcurl and grpc_health_probe,
// tools people already have. Reflection is registered so grpcurl can discover it without a proto.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

// Set per-Deployment so every response says which workload answered — the response is the
// evidence of which route matched, rather than something inferred.
func name() string {
	if n := os.Getenv("APP_NAME"); n != "" {
		return n
	}
	return "unnamed"
}

func serveHTTP(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Echoing Host and X-Forwarded-* proves which listener and hostname the Gateway matched,
		// which is the whole point of the wildcard-vs-exact demo.
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"app":%q,"mode":"http","path":%q,"host":%q,"method":%q,"proto":%q,"tls":%v}`+"\n",
			name(), r.URL.Path, r.Host, r.Method, r.Proto,
			strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"))
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
	log.Printf("%s: HTTP on %s", name(), addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func serveGRPC(addr string) {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	s := grpc.NewServer()
	hs := health.NewServer()
	hs.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	// A named service too, so a GRPCRoute can match on service name rather than only on host.
	hs.SetServingStatus("routedemo.Echo", healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(s, hs)
	reflection.Register(s) // lets grpcurl work without a .proto
	log.Printf("%s: gRPC on %s", name(), addr)
	log.Fatal(s.Serve(lis))
}

func serveTCP(addr string) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%s: TCP echo on %s", name(), addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			// Greet on connect so a bare `nc` shows which backend answered without sending anything.
			fmt.Fprintf(c, "hello from %s (tcp echo)\n", name())
			buf := make([]byte, 4096)
			for {
				n, err := c.Read(buf)
				if err != nil {
					return
				}
				fmt.Fprintf(c, "%s echoed: %s", name(), string(buf[:n]))
			}
		}(c)
	}
}

func main() {
	mode := flag.String("mode", "http", "http | grpc | tcp")
	addr := flag.String("addr", ":8080", "listen address")
	flag.Parse()
	_ = context.Background()
	switch *mode {
	case "http":
		serveHTTP(*addr)
	case "grpc":
		serveGRPC(*addr)
	case "tcp":
		serveTCP(*addr)
	default:
		log.Fatalf("unknown -mode %q (want http, grpc or tcp)", *mode)
	}
}
