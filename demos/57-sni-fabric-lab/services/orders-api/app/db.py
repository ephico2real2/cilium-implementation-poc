"""Postgres access through Envoy's mesh_pg listener, with start-up retries."""

import asyncio
import logging
import random
from typing import Any

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from .config import settings
from .metrics import DB_READY

log = logging.getLogger("orders-api.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    id               BIGSERIAL PRIMARY KEY,
    item             TEXT        NOT NULL,
    quantity         INTEGER     NOT NULL CHECK (quantity BETWEEN 1 AND 20),
    status           TEXT        NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'processed', 'failed')),
    idempotency_key  UUID        NOT NULL UNIQUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at     TIMESTAMPTZ,
    events_sent      INTEGER     NOT NULL DEFAULT 0,
    last_event_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS orders_status_created ON orders (status, created_at);
-- The W3C traceparent of the request that created the order, so that a re-sent event joins that
-- trace (R1.5). Added this way, a database created before R1.5 gets it too.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS traceparent TEXT;
"""

COLUMNS = "id, item, quantity, status, created_at, processed_at, events_sent, last_event_at, traceparent"

pool = AsyncConnectionPool(
    conninfo="",
    kwargs={"host": settings.db_host, "port": settings.db_port, "dbname": settings.db_name,
            "user": settings.db_user, "password": settings.db_password, "connect_timeout": 3,
            "application_name": "orders-api", "row_factory": dict_row},
    min_size=1, max_size=10, open=False,
    # Checks each connection before lending it, so a Postgres restart costs one failed check,
    # not a failed request.
    check=AsyncConnectionPool.check_connection,
)

ready = asyncio.Event()


async def connect_with_retry() -> None:
    """Opens the pool and applies the schema, retrying with capped exponential back-off and
    jitter until Postgres answers. /readyz stays false until this returns."""
    await pool.open(wait=False)
    attempt = 0
    while True:
        attempt += 1
        try:
            async with pool.connection() as conn:
                await conn.execute(SCHEMA)
            ready.set()
            DB_READY.set(1)
            log.info("database ready after %d attempt(s)", attempt)
            return
        except Exception as exc:  # noqa: BLE001 - any failure means "not yet"; keep trying
            delay = random.uniform(0, min(10.0, 0.5 * 2 ** min(attempt, 6)))
            log.warning("database not ready (attempt %d): %s; retrying in %.1fs", attempt, exc, delay)
            await asyncio.sleep(delay)


def to_api(row: dict[str, Any]) -> dict[str, Any]:
    out = {k: row[k] for k in ("id", "item", "quantity", "status", "events_sent")}
    for k in ("created_at", "processed_at", "last_event_at"):
        out[k] = row[k].isoformat() if row[k] else None
    return out
