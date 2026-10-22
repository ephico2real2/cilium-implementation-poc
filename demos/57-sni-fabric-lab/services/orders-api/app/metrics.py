"""Prometheus metrics, served on the internal server's /metrics."""

from prometheus_client import Counter, Gauge, Histogram

HTTP_REQUESTS = Counter("orders_api_http_requests_total", "HTTP requests handled",
                        ["server", "method", "route", "status"])
HTTP_LATENCY = Histogram("orders_api_http_request_seconds", "HTTP request duration",
                         ["server", "method", "route"],
                         buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
ORDERS_CREATED = Counter("orders_api_orders_created_total", "Orders created")
ORDERS_REPLAYED = Counter("orders_api_orders_replayed_total",
                          "POST /orders repeats answered from the stored order (same Idempotency-Key)")
STATUS_UPDATES = Counter("orders_api_status_updates_total", "Status updates applied", ["status"])
MQ_PUBLISH = Counter("orders_api_mq_publish_total", "Order events put on MQ", ["result", "reason"])
SWEEPS = Counter("orders_api_sweep_republish_total", "Events sent again by the sweeper")
TCP_PING = Counter("orders_api_tcp_ping_total", "PINGs to tcp-svc", ["result"])
CHAOS = Counter("orders_api_chaos_injected_total", "Requests the chaos switch failed or slowed", ["kind"])
DB_READY = Gauge("orders_api_db_ready", "1 when the database is reachable and migrated")
