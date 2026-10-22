"""orders-api: two servers in one process, both reached only through Envoy.

public   :8443 TLS   edge_sni (browser)   /orders, /tcp/ping, /admin/*, /docs
internal :8080 HTTP  mesh_http (worker)   PUT /orders/{id}/status, /metrics, /healthz, /readyz
"""

import asyncio
import contextlib
import hmac
import json
import logging
import random
import signal
import sys
import time
import uuid
from typing import Annotated, Any, Literal

import uvicorn
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from . import clients, db
from .config import settings
from .metrics import (CHAOS, HTTP_LATENCY, HTTP_REQUESTS, ORDERS_CREATED, ORDERS_REPLAYED,
                      STATUS_UPDATES, SWEEPS)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"), "level": record.levelname,
                           "logger": record.name, "msg": record.getMessage()})


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler])
log = logging.getLogger("orders-api")

# The chaos switch: set from the admin portal, applied to the internal status updates only,
# so Envoy's retries on the worker's PUTs become visible.
chaos: dict[str, float] = {"fail_rate": 0.0, "delay_ms": 0}


# ---------------------------------------------------------------- models

class OrderIn(BaseModel):
    item: str = Field(min_length=1, max_length=40)
    quantity: int = Field(ge=1, le=20)


class Order(BaseModel):
    id: int
    item: str
    quantity: int
    status: str
    created_at: str
    processed_at: str | None
    events_sent: int
    last_event_at: str | None


class StatusIn(BaseModel):
    status: Literal["processed", "failed"]


class ChaosIn(BaseModel):
    fail_rate: float = Field(ge=0, le=1)
    delay_ms: int = Field(ge=0, le=5000)


# ---------------------------------------------------------------- shared helpers

def instrument(app: FastAPI, server: str) -> None:
    @app.middleware("http")
    async def record(request: Request, call_next):
        started = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            route = getattr(request.scope.get("route"), "path", "unmatched")
            HTTP_REQUESTS.labels(server, request.method, route, str(status)).inc()
            HTTP_LATENCY.labels(server, request.method, route).observe(time.perf_counter() - started)


async def record_event_sent(order_id: int) -> None:
    async with db.pool.connection() as conn:
        await conn.execute("UPDATE orders SET events_sent = events_sent + 1, last_event_at = now() WHERE id = %s",
                           (order_id,))


async def send_event(order: dict[str, Any]) -> tuple[bool, str]:
    ok, reason = await clients.publish_order_event(order)
    if ok:
        await record_event_sent(order["id"])
    return ok, reason


async def fetch_order(order_id: int) -> dict[str, Any]:
    async with db.pool.connection() as conn:
        row = await (await conn.execute(f"SELECT {db.COLUMNS} FROM orders WHERE id = %s", (order_id,))).fetchone()
    if row is None:
        raise HTTPException(404, "order not found")
    return row


def require_db() -> None:
    if not db.ready.is_set():
        raise HTTPException(503, "database not ready")


# ---------------------------------------------------------------- public app

public = FastAPI(title="orders-api", version="1.0.0",
                 description="Orders for the SNI fabric lab. Reached only through Envoy's shared TLS port.")
public.add_middleware(CORSMiddleware, allow_origins=list(settings.cors_origins),
                      allow_methods=["GET", "POST", "PUT"],
                      allow_headers=["Content-Type", "Idempotency-Key", "Authorization"],
                      expose_headers=["Idempotent-Replayed"], max_age=600)
instrument(public, "public")


@public.get("/orders", response_model=list[Order], dependencies=[Depends(require_db)])
async def list_orders(limit: Annotated[int, Query(ge=1, le=100)] = 20,
                      status: Literal["created", "processed", "failed"] | None = None):
    query = f"SELECT {db.COLUMNS} FROM orders"
    params: tuple = ()
    if status:
        query += " WHERE status = %s"
        params = (status,)
    async with db.pool.connection() as conn:
        rows = await (await conn.execute(query + " ORDER BY id DESC LIMIT %s", (*params, limit))).fetchall()
    return [db.to_api(r) for r in rows]


@public.get("/orders/{order_id}", response_model=Order, dependencies=[Depends(require_db)])
async def get_order(order_id: int):
    return db.to_api(await fetch_order(order_id))


@public.post("/orders", response_model=Order, status_code=201, dependencies=[Depends(require_db)],
             responses={200: {"description": "A repeat of an earlier request with the same Idempotency-Key"},
                        422: {"description": "Idempotency-Key reused with a different request body"}})
async def create_order(body: OrderIn, response: Response,
                       idempotency_key: Annotated[uuid.UUID, Header(description="A UUID, the same on every retry")]):
    """Creates an order and puts an `order.created` event on MQ. A retry with the same
    Idempotency-Key returns the original order instead of creating a second one."""
    async with db.pool.connection() as conn:
        row = await (await conn.execute(
            f"INSERT INTO orders (item, quantity, idempotency_key) VALUES (%s, %s, %s) "
            f"ON CONFLICT (idempotency_key) DO NOTHING RETURNING {db.COLUMNS}",
            (body.item, body.quantity, idempotency_key))).fetchone()
        if row is None:
            existing = await (await conn.execute(
                f"SELECT {db.COLUMNS} FROM orders WHERE idempotency_key = %s", (idempotency_key,))).fetchone()
            if (existing["item"], existing["quantity"]) != (body.item, body.quantity):
                raise HTTPException(422, "Idempotency-Key was already used with a different request")
            ORDERS_REPLAYED.inc()
            response.status_code = 200
            response.headers["Idempotent-Replayed"] = "true"
            return db.to_api(existing)
    ORDERS_CREATED.inc()
    ok, reason = await send_event(row)
    if not ok:
        log.warning("order %s created; event not sent (%s); the sweeper will retry", row["id"], reason)
    return db.to_api(await fetch_order(row["id"]))


@public.get("/tcp/ping")
async def tcp_ping():
    """Sends PING to tcp-svc over TLS through Envoy's shared port and returns the reply."""
    try:
        return await clients.ping_tcp()
    except ConnectionError as exc:
        raise HTTPException(502, str(exc)) from exc


# ---------------------------------------------------------------- admin (public, token-protected)

# Declared as a bearer scheme so Swagger UI offers "Authorize" for the /admin calls.
# auto_error=False: a missing token gets this API's own 401, not FastAPI's 403.
admin_bearer = HTTPBearer(auto_error=False, description="The admin token (lab value: fabric-admin)")


def require_admin(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(admin_bearer)]) -> None:
    supplied = credentials.credentials if credentials else ""
    if not hmac.compare_digest(supplied.encode(), settings.admin_token.encode()):
        raise HTTPException(401, "admin token required", headers={"WWW-Authenticate": "Bearer"})


admin = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])

# PromQL behind the portal's Fabric and MQ panels.
QUERIES = {
    # edge_sni tenants only; "postgres" is mesh_pg's TCP proxy, not an SNI tenant.
    "tenants": 'sum by (envoy_tcp_prefix) (envoy_tcp_downstream_cx_total{envoy_tcp_prefix!="postgres"})',
    # Envoy's counter names get _total at the scrape (observability/prometheus.yml).
    "rejected": 'sum(envoy_listener_no_filter_chain_match_total{envoy_listener_address="0.0.0.0_10443"})',
    "retries": "sum by (envoy_cluster_name) (envoy_cluster_upstream_rq_retry_total)",
    "retry_success": "sum by (envoy_cluster_name) (envoy_cluster_upstream_rq_retry_success_total)",
    # The MQ container exports queue-manager-wide counters only (ibmmq_qmgr_*).
    "puts": "sum(ibmmq_qmgr_mqput_mqput1_total)",
    "gets": "sum(ibmmq_qmgr_destructive_get_total)",
    "worker_last_event": "max(worker_last_event_timestamp_seconds)",
}


async def _check(name: str, coro) -> dict[str, Any]:
    """ok is True or False for a component that was checked, None for one not configured."""
    try:
        ok, detail = await asyncio.wait_for(coro, timeout=4)
    except Exception as exc:  # noqa: BLE001 - a failed check is a result, not an error
        ok, detail = False, f"{type(exc).__name__}: {exc}"[:120]
    return {"name": name, "ok": ok, "detail": detail}


async def _db_ok() -> tuple[bool, str]:
    if not db.ready.is_set():
        return False, "not ready"
    async with db.pool.connection() as conn:
        await conn.execute("SELECT 1")
    return True, "SELECT 1 through mesh_pg"


async def _tcp_ok() -> tuple[bool, str]:
    result = await clients.ping_tcp(attempts=1)
    return result["reply"] == "PONG", f"{result['reply']} in {result['latency_ms']} ms"


async def _optional(url: str, client) -> tuple[bool | None, str]:
    if not url:
        return None, "not configured"
    return await clients.http_ok(client, url)


def _scalar(result: list[dict[str, Any]]) -> float | None:
    return float(result[0]["value"][1]) if result else None


async def _prometheus_panels() -> tuple[dict[str, Any], dict[str, Any]]:
    if not settings.prometheus_url:
        error = {"error": "Prometheus not configured yet"}
        return error, error
    try:
        names = list(QUERIES)
        results = dict(zip(names, await asyncio.gather(*(clients.prometheus_query(QUERIES[n]) for n in names))))
    except Exception as exc:  # noqa: BLE001
        error = {"error": f"Prometheus: {type(exc).__name__}: {exc}"[:160]}
        return error, error
    success = {r["metric"].get("envoy_cluster_name"): int(float(r["value"][1])) for r in results["retry_success"]}
    fabric = {
        "tenants": sorted(({"name": r["metric"].get("envoy_tcp_prefix", "?"), "connections": int(float(r["value"][1]))}
                           for r in results["tenants"]), key=lambda t: t["name"]),
        "rejected": int(_scalar(results["rejected"]) or 0),
        "retries": sorted(({"cluster": r["metric"].get("envoy_cluster_name", "?"), "retries": int(float(r["value"][1])),
                            "retry_success": success.get(r["metric"].get("envoy_cluster_name"), 0)}
                           for r in results["retries"] if float(r["value"][1]) > 0), key=lambda r: r["cluster"]),
    }
    last = _scalar(results["worker_last_event"])
    mq: dict[str, Any] = {key: (None if _scalar(results[key]) is None else int(_scalar(results[key])))
                          for key in ("puts", "gets")}
    try:
        mq["queue_waiting"], mq["dead_letter_waiting"] = await asyncio.gather(
            clients.mq_waiting(settings.mq_queue), clients.mq_waiting("DEV.DEAD.LETTER.QUEUE"))
    except Exception as exc:  # noqa: BLE001 - the panel shows what it could not read
        mq["queue_waiting"] = mq["dead_letter_waiting"] = f"browse failed: {type(exc).__name__}"
    mq["worker_last_event"] = (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last)) if last else None)
    return fabric, mq


@admin.get("/overview")
async def overview():
    """Everything the admin portal shows, in one call."""
    health = await asyncio.gather(
        _check("envoy", _optional(settings.envoy_ready_url, clients.mesh)),
        _check("postgres", _db_ok()),
        _check("web", clients.http_ok(clients.edge, settings.web_health_url)),
        _check("tcp-svc", _tcp_ok()),
        _check("mq", clients.mq_browse_ok()),
        _check("worker", _optional(settings.worker_metrics_url, clients.mesh)),
    )
    by_status: dict[str, int] = {}
    if db.ready.is_set():
        async with db.pool.connection() as conn:
            rows = await (await conn.execute("SELECT status, count(*) AS n FROM orders GROUP BY status")).fetchall()
        by_status = {r["status"]: r["n"] for r in rows}
    fabric, mq = await _prometheus_panels()
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "health": list(health),
            "fabric": fabric, "mq": mq, "orders": {"by_status": by_status}, "chaos": dict(chaos)}


@admin.get("/orders", response_model=list[Order], dependencies=[Depends(require_db)])
async def admin_orders(limit: Annotated[int, Query(ge=1, le=200)] = 50,
                       status: Literal["created", "processed", "failed"] | None = None):
    return await list_orders(limit=limit, status=status)


@admin.post("/orders/{order_id}/republish", dependencies=[Depends(require_db)])
async def republish(order_id: int):
    """Sends a still-created order's event again (what the sweeper does on a timer)."""
    order = await fetch_order(order_id)
    if order["status"] != "created":
        raise HTTPException(409, f"order is already {order['status']}")
    ok, reason = await send_event(order)
    if not ok:
        raise HTTPException(502, f"event not sent: {reason}")
    return db.to_api(await fetch_order(order_id))


@admin.put("/chaos")
async def set_chaos(body: ChaosIn):
    chaos.update(fail_rate=body.fail_rate, delay_ms=body.delay_ms)
    log.warning("chaos set: fail_rate=%.2f delay_ms=%d", body.fail_rate, body.delay_ms)
    return dict(chaos)


public.include_router(admin)


# ---------------------------------------------------------------- internal app

internal = FastAPI(title="orders-api internal", docs_url=None, redoc_url=None, openapi_url=None)
instrument(internal, "internal")


@internal.get("/metrics")
async def metrics():
    # A plain route rather than a mounted app: a mount answers /metrics with a redirect to
    # /metrics/, which a scraper behind a path-rewriting proxy cannot follow.
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def require_worker(authorization: Annotated[str | None, Header()] = None) -> None:
    """Envoy routes api.mesh from every lab network, so reaching this server says nothing about
    who is calling: only the worker holds the token that may change an order's status."""
    expected = settings.worker_token
    scheme, separator, supplied = (authorization or "").partition(" ")
    valid_shape = separator == " " and scheme == "Bearer" and bool(supplied) and " " not in supplied
    matches = hmac.compare_digest(supplied.encode(), expected.encode())
    if not expected or not valid_shape or not matches:
        raise HTTPException(401, "worker token required", headers={"WWW-Authenticate": "Bearer"})


@internal.put("/orders/{order_id}/status", dependencies=[Depends(require_worker), Depends(require_db)])
async def update_status(order_id: int, body: StatusIn):
    """Idempotent: repeating the same update leaves the order as it is, so Envoy may retry it."""
    if chaos["delay_ms"]:
        CHAOS.labels("delay").inc()
        await asyncio.sleep(chaos["delay_ms"] / 1000)
    if chaos["fail_rate"] and random.random() < chaos["fail_rate"]:
        CHAOS.labels("fail").inc()
        return JSONResponse({"detail": "chaos: injected failure"}, status_code=503)
    async with db.pool.connection() as conn:
        row = await (await conn.execute(
            f"UPDATE orders SET status = %s, processed_at = COALESCE(processed_at, now()) "
            f"WHERE id = %s RETURNING {db.COLUMNS}", (body.status, order_id))).fetchone()
    if row is None:
        raise HTTPException(404, "order not found")
    STATUS_UPDATES.labels(body.status).inc()
    return db.to_api(row)


@internal.get("/healthz")
async def healthz():
    return {"status": "ok"}


@internal.get("/readyz")
async def readyz():
    if not db.ready.is_set():
        return JSONResponse({"status": "database not ready"}, status_code=503)
    return {"status": "ready"}


# ---------------------------------------------------------------- background work

async def sweeper() -> None:
    """Sends the event again for every order still "created" a while after its last event.
    This closes the gap the MQ REST API leaves: a worker that dies between its destructive get
    and its status update loses the message, but not the order."""
    while True:
        await asyncio.sleep(settings.sweep_every_s)
        if not db.ready.is_set() or not settings.mq_rest_url:
            continue
        try:
            async with db.pool.connection() as conn:
                stuck = await (await conn.execute(
                    f"SELECT {db.COLUMNS} FROM orders WHERE status = 'created' "
                    f"AND COALESCE(last_event_at, created_at) < now() - make_interval(secs => %s) "
                    f"ORDER BY id LIMIT 50", (settings.sweep_after_s,))).fetchall()
            for order in stuck:
                ok, reason = await send_event(order)
                SWEEPS.inc()
                log.info("sweeper re-sent order %s: %s", order["id"], "ok" if ok else reason)
        except Exception as exc:  # noqa: BLE001 - the sweeper must survive a bad round
            log.warning("sweep failed: %s", exc)


class Server(uvicorn.Server):
    """A uvicorn server that leaves signal handling to main(), which stops both servers."""

    @contextlib.contextmanager
    def capture_signals(self):
        yield


async def main() -> None:
    servers = [
        Server(uvicorn.Config(public, host="0.0.0.0", port=settings.public_port, lifespan="off",
                              ssl_certfile=f"{settings.tls_dir}/tls.crt", ssl_keyfile=f"{settings.tls_dir}/tls.key",
                              proxy_headers=False, server_header=False, log_config=None)),
        Server(uvicorn.Config(internal, host="0.0.0.0", port=settings.internal_port, lifespan="off",
                              server_header=False, log_config=None)),
    ]
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: [setattr(s, "should_exit", True) for s in servers])
    background = [asyncio.create_task(db.connect_with_retry()), asyncio.create_task(sweeper())]
    log.info("starting: public :%d (TLS), internal :%d", settings.public_port, settings.internal_port)
    await asyncio.gather(*(s.serve() for s in servers))
    for task in background:
        task.cancel()
    await db.pool.close()
    log.info("stopped")


if __name__ == "__main__":
    asyncio.run(main())
