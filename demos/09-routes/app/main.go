// A single binary that can play three roles, selected with -mode. One image, three workloads,
// three Gateway API route types.
//
//	-mode http   plain HTTP server           -> HTTPRoute
//	-mode grpc   gRPC server                 -> GRPCRoute
//	-mode tcp    line-echo TCP server        -> TCPRoute
//
//	-mode client native test client        -> exercises all three routes through the Gateway
//
// WHY ONE BINARY INSTEAD OF THREE. Three images means three builds, three pushes and three
// `kind load` steps on a laptop that just ran out of disk. One static binary keeps the image at a
// few megabytes and makes the three deployments differ by a single argument, which also makes the
// comparison between route types the only variable.
//
// WHY A CLIENT MODE IN THE SAME BINARY. The routes were first verified with a grpcurl container
// and `nc`, which proves the routes but is not something a junior can run on a laptop without
// Docker. The client mode speaks the same three protocols natively -- HTTPS with the enterprise
// root, gRPC over h2c and over TLS with SNI, and the raw TCP echo -- pins each hostname to the
// Gateway address the way `curl --resolve` does (no /etc/hosts needed), and exits with the number
// of failed checks. Build it for the machine you are on: `go build -o routedemo .`
//
// WHY THE gRPC SIDE USES THE HEALTH SERVICE. A normal gRPC demo needs a .proto file, protoc, and
// generated stubs checked in or generated at build time. grpc-go already ships the standard
// Health service (grpc.health.v1.Health), so we get a REAL gRPC service -- real HTTP/2, real
// protobuf framing -- with no codegen at all, and it is callable by grpcurl and grpc_health_probe,
// tools people already have. Reflection is registered so grpcurl can discover it without a proto.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
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

func writeJSONHTML(w http.ResponseWriter, code int, compact []byte, title string) {
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, compact, "", "  "); err != nil {
		pretty.Reset()
		pretty.Write(compact)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	fmt.Fprintf(w, `<!doctype html>
<title>%s</title>
<style>
body{background:#0f172a;margin:0}
pre{font-family:monospace;font-size:14px;color:#e2e8f0;padding:1.5rem}
.note{color:#94a3b8;padding:0 1.5rem 1.5rem;font-size:14px}
</style>
<pre>%s</pre>
<p class="note">curl gets the same JSON, compact — this page is the browser's view (Accept: text/html)</p>
`, html.EscapeString(title), html.EscapeString(pretty.String()))
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	// Echoing Host and X-Forwarded-* proves which listener and hostname the Gateway matched,
	// which is the whole point of the wildcard-vs-exact demo.
	compact := fmt.Sprintf(`{"app":%q,"mode":"http","path":%q,"host":%q,"method":%q,"proto":%q,"tls":%v}`+"\n",
		name(), r.URL.Path, r.Host, r.Method, r.Proto,
		strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"))
	if wantsHTML(r) {
		writeJSONHTML(w, http.StatusOK, []byte(compact), name())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, compact)
}

func serveHTTP(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
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

// ---- client mode -------------------------------------------------------------------------------

// checker counts failures so the process exit code is the number of checks that failed, which is
// what lets a transcript or a pipeline read the result without parsing text.
type checker struct{ failed int }

func (c *checker) pass(format string, a ...any) { fmt.Printf("  PASS  "+format+"\n", a...) }
func (c *checker) fail(format string, a ...any) {
	c.failed++
	fmt.Printf("  FAIL  "+format+"\n", a...)
}

// pinnedDialer is the programmatic form of `curl --resolve`: whatever hostname the client asks
// for, the TCP connection goes to the Gateway address. TLS SNI and the Host/:authority header still
// carry the real name, which is what the Gateway routes on. Nothing on the machine is touched.
func pinnedDialer(target string) func(ctx context.Context, network, addr string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		_, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(target, port))
	}
}

// findCA makes the default -ca work from any directory in the repo. The path is relative to the
// repo root, but people build from demos/09-routes/app and run from there -- so if it does not
// exist as given, look for the same relative path in each parent directory. An explicit -ca that
// does not exist is still an error, with the path that would have worked from here.
func findCA(path string) string {
	if _, err := os.Stat(path); err == nil {
		return path
	}
	if filepath.IsAbs(path) {
		return path
	}
	dir, err := os.Getwd()
	if err != nil {
		return path
	}
	for i := 0; i < 8; i++ {
		candidate := filepath.Join(dir, path)
		if _, err := os.Stat(candidate); err == nil {
			log.Printf("using CA %s (found by walking up from the current directory)", candidate)
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return path
}

func loadRoots(path string) *x509.CertPool {
	pem, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf("read CA %s: %v\n  pass -ca <path to docs/root-ca.crt>; from demos/09-routes/app that is -ca ../../../docs/root-ca.crt", path, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		log.Fatalf("no certificate found in %s", path)
	}
	return pool
}

func httpGet(client *http.Client, url string) (int, string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, strings.TrimSpace(string(body)), nil
}

func runClient(target, caPath, domain, exact, only string) int {
	c := &checker{}
	// -only narrows the run to one route type (http | grpc | tcp); "all" runs every section.
	want := func(section string) bool { return only == "all" || only == section }
	caPath = findCA(caPath)
	roots := loadRoots(caPath)
	dial := pinnedDialer(target)
	https := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		DialContext: dial, TLSClientConfig: &tls.Config{RootCAs: roots}}}
	plain := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{DialContext: dial}}

	fmt.Printf("Gateway %s, root CA %s, wildcard domain *.%s, exact host %s\n\n", target, caPath, domain, exact)

	if want("http") {
		fmt.Println("1. HTTPRoute over HTTPS -- chain verified against the root, SNI selects the listener")
		for _, h := range []string{"web." + domain, "anything-at-all." + domain, exact} {
			code, body, err := httpGet(https, "https://"+h+"/")
			switch {
			case err != nil:
				c.fail("https://%s/  %v", h, err)
			case code != 200:
				c.fail("https://%s/  http %d", h, code)
			case !strings.Contains(body, `"host":"`+h+`"`) || !strings.Contains(body, `"tls":true`):
				c.fail("https://%s/  200 but the app did not echo host+tls: %s", h, body)
			default:
				c.pass("https://%s/  200, app echoed host and tls=true", h)
			}
		}
		if code, _, err := httpGet(https, "https://nobody."+domain+"/"); err != nil || code != 404 {
			c.fail("https://nobody.%s/  want 404 (under the wildcard, no route), got %d %v", domain, code, err)
		} else {
			c.pass("https://nobody.%s/  404 -- wildcard cert served it, no HTTPRoute claimed it", domain)
		}
		if _, _, err := httpGet(https, "https://nobody.example.test/"); err == nil {
			c.fail("https://nobody.example.test/  the exact listener must NOT present a cert for another name")
		} else {
			c.pass("https://nobody.example.test/  TLS refused as expected: %v", errString(err))
		}

		fmt.Println("\n2. HTTPRoute over plain HTTP :80 -- the Host header picks the route")
		req, _ := http.NewRequest("GET", "http://"+target+"/", nil)
		req.Host = "web." + domain
		if resp, err := plain.Do(req); err != nil || resp.StatusCode != 200 {
			c.fail("http://%s/ Host: web.%s  %v", target, domain, err)
		} else {
			resp.Body.Close()
			c.pass("http://%s/ Host: web.%s  200", target, domain)
		}

	}

	if want("grpc") {
		fmt.Println("\n3. GRPCRoute -- grpc.health.v1.Health/Check, over h2c (:80) and over TLS (:443)")
		grpcHost := "grpc." + domain
		grpcCheck := func(label string, port string, creds credentials.TransportCredentials) {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			// grpc-go dials the target string; the authority (and TLS ServerName) is the route hostname.
			conn, err := grpc.NewClient(net.JoinHostPort(target, port),
				grpc.WithTransportCredentials(creds), grpc.WithAuthority(grpcHost))
			if err != nil {
				c.fail("%s  dial: %v", label, err)
				return
			}
			defer conn.Close()
			resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
			if err != nil {
				c.fail("%s  %v", label, err)
				return
			}
			if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
				c.fail("%s  status %s", label, resp.GetStatus())
				return
			}
			c.pass("%s  SERVING", label)
		}
		grpcCheck("h2c  "+grpcHost+":80 ", "80", insecure.NewCredentials())
		grpcCheck("TLS  "+grpcHost+":443", "443", credentials.NewTLS(&tls.Config{RootCAs: roots, ServerName: grpcHost}))

	}

	if want("tcp") {
		fmt.Println("\n4. TCPRoute :9000 -- greeting on connect, then a line echoed back")
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(target, "9000"), 5*time.Second)
		if err != nil {
			c.fail("tcp %s:9000  %v", target, err)
		} else {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			r := bufio.NewReader(conn)
			greet, err := r.ReadString('\n')
			if err != nil || !strings.Contains(greet, "(tcp echo)") {
				c.fail("tcp greeting: %q %v", greet, err)
			} else {
				fmt.Fprintf(conn, "ping from routedemo client\n")
				echo, err := r.ReadString('\n')
				if err != nil || !strings.Contains(echo, "echoed: ping from routedemo client") {
					c.fail("tcp echo: %q %v", echo, err)
				} else {
					c.pass("tcp  greeting %q then %q", strings.TrimSpace(greet), strings.TrimSpace(echo))
				}
			}
		}

	}

	fmt.Printf("\nFAILED CHECKS: %d\n", c.failed)
	return c.failed
}

// errString keeps a TLS failure to one line so the transcript stays readable.
func errString(err error) string {
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 && i+2 < len(s) {
		return s[i+2:]
	}
	return s
}

func main() {
	mode := flag.String("mode", "http", "http | grpc | tcp | client")
	addr := flag.String("addr", ":8080", "listen address (server modes)")
	target := flag.String("target", "", "client: Gateway address, e.g. 172.18.255.240")
	caPath := flag.String("ca", "docs/root-ca.crt", "client: root CA to verify the Gateway's certificates")
	domain := flag.String("domain", "poc.local", "client: the wildcard domain (*.poc.local)")
	exact := flag.String("exact", "exact.example.test", "client: the exact-listener hostname")
	only := flag.String("only", "all", "client: run only one route type: http | grpc | tcp")
	flag.Parse()
	switch *mode {
	case "http":
		serveHTTP(*addr)
	case "grpc":
		serveGRPC(*addr)
	case "tcp":
		serveTCP(*addr)
	case "client":
		if *target == "" {
			log.Fatal("-mode client needs -target <gateway address>")
		}
		switch *only {
		case "all", "http", "grpc", "tcp":
		default:
			log.Fatalf("unknown -only %q (want http, grpc, tcp or all)", *only)
		}
		os.Exit(runClient(*target, *caPath, *domain, *exact, *only))
	default:
		log.Fatalf("unknown -mode %q (want http, grpc, tcp or client)", *mode)
	}
}
