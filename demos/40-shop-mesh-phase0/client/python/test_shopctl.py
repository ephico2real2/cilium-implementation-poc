#!/usr/bin/env python3
"""unittest for shopctl.py — flag parsing, per-second aggregation on a fake server, the exit-code rule."""
from __future__ import annotations

import io
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import shopctl


class Handler(BaseHTTPRequestHandler):
    status = 200

    def log_message(self, fmt, *args):  # noqa: A003 — silence the test server
        return

    def do_GET(self):
        self.send_response(self.status)
        self.send_header("X-Served-By", "test")
        self.end_headers()
        self.wfile.write(b"ok\n")


def serve(status: int) -> tuple[ThreadingHTTPServer, str]:
    Handler.status = status
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    host, port = httpd.server_address
    return httpd, f"http://{host}:{port}"


class ParseArgs(unittest.TestCase):
    def test_probe_url_required(self):
        with self.assertRaises(SystemExit):
            shopctl.parse_args(["probe"])

    def test_probe_flags(self):
        ns = shopctl.parse_args(["probe", "--url", "https://api.shop.poc.local", "-k", "--timeout", "1"])
        self.assertEqual(ns.cmd, "probe")
        self.assertTrue(ns.insecure)
        self.assertEqual(ns.timeout, 1.0)

    def test_load_flags(self):
        ns = shopctl.parse_args(
            ["load", "--url", "https://x/", "--rate", "5", "--duration", "3", "--path", "ready"]
        )
        self.assertEqual(ns.rate, 5)
        self.assertEqual(ns.duration, 3.0)
        self.assertEqual(ns.path, "ready")


class Aggregation(unittest.TestCase):
    def test_aggregate_and_join(self):
        hits = [
            {"status": 200, "served": "poc1", "err": None, "latency_ms": 1},
            {"status": 200, "served": "poc2", "err": None, "latency_ms": 2},
            {"status": 500, "served": "poc1", "err": None, "latency_ms": 3},
            {"status": 0, "served": "", "err": OSError("down"), "latency_ms": 4},
        ]
        agg = shopctl.aggregate_second(2, hits)
        self.assertEqual(agg["ok"], 2)
        self.assertEqual(agg["fail"], 2)
        self.assertEqual(shopctl.join_served(agg["served"]), "poc1,poc2")


class FakeServer(unittest.TestCase):
    def test_load_ok_exit_zero(self):
        httpd, url = serve(200)
        try:
            buf = io.StringIO()
            code = shopctl.run_load(url, "/healthz", 4, 2, 1.0, None, out=buf)
            out = buf.getvalue()
            self.assertEqual(code, 0, out)
            self.assertIn("SECOND", out)
            self.assertIn("X-SERVED-BY", out)
            self.assertIn("latency_ms", out)
            self.assertIn("test", out)
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_load_fail_seconds_is_exit_code(self):
        httpd, url = serve(500)
        try:
            buf = io.StringIO()
            code = shopctl.run_load(url, "/healthz", 3, 2, 1.0, None, out=buf)
            self.assertEqual(code, 2, buf.getvalue())
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_probe_counts_non_2xx(self):
        httpd, url = serve(404)
        try:
            buf = io.StringIO()
            code = shopctl.run_probe(url, 1.0, None, out=buf)
            self.assertEqual(code, 3, buf.getvalue())
            self.assertIn("/healthz", buf.getvalue())
            self.assertIn("test", buf.getvalue())
        finally:
            httpd.shutdown()
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()
