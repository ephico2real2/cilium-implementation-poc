"""Outbound calls: MQ REST (put), tcp-svc (PING), health checks, Prometheus. All go through Envoy."""

import asyncio
import json
import logging
import random
import ssl
import time
from typing import Any

import httpx

from .config import settings
from .metrics import MQ_PUBLISH, TCP_PING

log = logging.getLogger("orders-api.clients")

# Plain HTTP to Envoy's mesh_http listener; Envoy opens TLS to MQ where needed.
mesh = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0))
# HTTPS through edge_sni, verified against the lab CA.
edge = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0), verify=ssl.create_default_context(cafile=settings.ca_file))


async def publish_order_event(order: dict[str, Any]) -> tuple[bool, str]:
    """Puts one order event on the queue through the MQ REST API. Returns (ok, reason).

    No retry here: Envoy retries the POST only if it never reached MQ, and the sweeper sends
    the event again later if the order is still "created"; the worker's update is idempotent.
    """
    if not settings.mq_rest_url:
        MQ_PUBLISH.labels("skipped", "mq disabled").inc()
        return False, "mq disabled"
    event = {"type": "order.created", "order_id": order["id"], "item": order["item"],
             "quantity": order["quantity"], "attempt": order["events_sent"] + 1}
    url = f"{settings.mq_rest_url}/messaging/qmgr/{settings.mq_qmgr}/queue/{settings.mq_queue}/message"
    try:
        response = await mesh.post(
            url, content=json.dumps(event),
            auth=(settings.mq_user, settings.mq_password),
            # The MQ REST API refuses POST/DELETE without this header (any value).
            headers={"ibm-mq-rest-csrf-token": "fabric", "Content-Type": "text/plain;charset=utf-8"},
        )
    except httpx.HTTPError as exc:
        MQ_PUBLISH.labels("error", type(exc).__name__).inc()
        return False, type(exc).__name__
    if response.status_code == 201:
        MQ_PUBLISH.labels("ok", "").inc()
        return True, ""
    MQ_PUBLISH.labels("error", f"http {response.status_code}").inc()
    log.warning("MQ put refused: %s %s", response.status_code, response.text[:200])
    return False, f"http {response.status_code}"


async def ping_tcp(attempts: int = 2) -> dict[str, Any]:
    """Opens TLS to tcp-svc through edge_sni, sends PING, returns the reply and the latency.
    Retries a failed connection once with jittered back-off; the command itself is harmless."""
    context = ssl.create_default_context(cafile=settings.ca_file)
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        started = time.perf_counter()
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(settings.tcp_host, settings.tcp_port, ssl=context,
                                        server_hostname=settings.tcp_host), timeout=3)
            try:
                writer.write(b"PING\n")
                await writer.drain()
                reply = (await asyncio.wait_for(reader.readline(), timeout=3)).decode().strip()
            finally:
                writer.close()
            TCP_PING.labels("ok").inc()
            return {"reply": reply, "latency_ms": round((time.perf_counter() - started) * 1000, 1),
                    "attempts": attempt}
        except (OSError, asyncio.TimeoutError, ssl.SSLError) as exc:
            last_error = exc
            if attempt < attempts:
                await asyncio.sleep(random.uniform(0, 0.2 * 2 ** attempt))
    TCP_PING.labels("error").inc()
    raise ConnectionError(f"tcp-svc unreachable: {type(last_error).__name__}: {last_error}")


async def http_ok(client: httpx.AsyncClient, url: str) -> tuple[bool, str]:
    try:
        response = await client.get(url)
    except httpx.HTTPError as exc:
        return False, type(exc).__name__
    return response.status_code < 400, f"HTTP {response.status_code}"


async def mq_browse_ok() -> tuple[bool | None, str]:
    """A non-destructive check of MQ: list (browse) the queue's messages."""
    if not settings.mq_rest_url:
        return None, "not configured"
    url = f"{settings.mq_rest_url}/messaging/qmgr/{settings.mq_qmgr}/queue/{settings.mq_queue}/messagelist"
    try:
        response = await mesh.get(url, auth=(settings.mq_user, settings.mq_password))
    except httpx.HTTPError as exc:
        return False, type(exc).__name__
    return response.status_code == 200, f"REST browse HTTP {response.status_code}"


async def mq_waiting(queue: str, limit: int = 100) -> int | None:
    """Messages waiting on a queue, counted by a browse (nothing is removed), up to limit.
    The MQ container's metrics are queue-manager-wide only, so per-queue depth comes from here."""
    if not settings.mq_rest_url:
        return None
    url = f"{settings.mq_rest_url}/messaging/qmgr/{settings.mq_qmgr}/queue/{queue}/messagelist"
    response = await mesh.get(url, params={"limit": limit}, auth=(settings.mq_user, settings.mq_password))
    response.raise_for_status()
    return len(response.json().get("messages", []))


async def prometheus_query(query: str) -> list[dict[str, Any]]:
    response = await mesh.get(f"{settings.prometheus_url}/api/v1/query", params={"query": query})
    response.raise_for_status()
    body = response.json()
    if body.get("status") != "success":
        raise RuntimeError(body.get("error", "query failed"))
    return body["data"]["result"]
