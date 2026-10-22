"""worker: takes order events off MQ and marks each order processed. Every call goes through Envoy.

Loop:
  1. Get one message from DEV.QUEUE.1 through the MQ REST API (Envoy mesh_http -> MQ :9443).
     The REST get is an HTTP DELETE that removes the message: there is no transaction to roll
     back, so Envoy never retries it once sent, and this loop handles every failure after it.
  2. PUT /orders/{id}/status on orders-api (Envoy mesh_http, which retries the idempotent PUT).
  3. If the update still fails, put the event back with attempt + 1; after MAX_ATTEMPTS, put
     it on DEV.DEAD.LETTER.QUEUE. If even the put-back fails, the event is lost here, and the
     API's sweeper sends it again because the order is still "created".
"""

import json
import logging
import os
import random
import signal
import sys
import time

import httpx
from prometheus_client import Counter, Gauge, Histogram, start_http_server

MQ_REST_URL = os.environ.get("MQ_REST_URL", "http://mqrest.mesh:18080/ibmmq/rest/v3")
MQ_QMGR = os.environ.get("MQ_QMGR", "QM1")
QUEUE = os.environ.get("MQ_QUEUE", "DEV.QUEUE.1")
DEAD_LETTER_QUEUE = os.environ.get("MQ_DEAD_LETTER_QUEUE", "DEV.DEAD.LETTER.QUEUE")
API_URL = os.environ.get("API_URL", "http://api.mesh:18080")
MQ_USER = os.environ.get("MQ_APP_USER", "app")
MQ_PASSWORD_FILE = os.environ.get("MQ_APP_PASSWORD_FILE", "/secrets/worker/mq-app-password")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "5"))
GET_WAIT_MS = int(os.environ.get("GET_WAIT_MS", "5000"))

MESSAGES = Counter("worker_messages_total", "Events handled, by outcome", ["result"])
GET_ERRORS = Counter("worker_get_errors_total", "Failed attempts to get a message", ["reason"])
LAST_EVENT = Gauge("worker_last_event_timestamp_seconds", "When the last event was handled")
UPDATE_SECONDS = Histogram("worker_status_update_seconds", "PUT /orders/{id}/status duration, Envoy retries included",
                           buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"), "level": record.levelname,
                           "msg": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("worker")

stopping = False


def stop(*_: object) -> None:
    global stopping
    stopping = True


def queue_url(queue: str) -> str:
    return f"{MQ_REST_URL}/messaging/qmgr/{MQ_QMGR}/queue/{queue}/message"


def backoff(attempt: int, cap: float = 10.0) -> float:
    """Full-jitter exponential back-off."""
    return random.uniform(0, min(cap, 0.25 * 2 ** min(attempt, 8)))


def main() -> None:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Create every outcome's series at 0, so a panel reads 0 rather than "No data" before the
    # first event of that kind.
    for result in ("processed", "requeued", "dead_lettered", "lost"):
        MESSAGES.labels(result)
    start_http_server(METRICS_PORT)
    with open(MQ_PASSWORD_FILE, encoding="utf-8") as handle:
        auth = (MQ_USER, handle.read().strip())
    # The MQ REST API refuses POST and DELETE without this header (any value).
    mq_headers = {"ibm-mq-rest-csrf-token": "fabric"}
    mq = httpx.Client(auth=auth, headers=mq_headers, timeout=httpx.Timeout(GET_WAIT_MS / 1000 + 5, connect=2))
    api = httpx.Client(timeout=httpx.Timeout(15, connect=2))

    def put(queue: str, event: dict) -> bool:
        try:
            response = mq.post(queue_url(queue), content=json.dumps(event),
                               headers={"Content-Type": "text/plain;charset=utf-8"})
            return response.status_code == 201
        except httpx.HTTPError as exc:
            log.warning("put to %s failed: %s", queue, exc)
            return False

    log.info("worker started: %s -> %s", queue_url(QUEUE), API_URL)
    failures = 0
    while not stopping:
        try:
            response = mq.delete(queue_url(QUEUE), params={"wait": GET_WAIT_MS})
        except httpx.HTTPError as exc:
            failures += 1
            GET_ERRORS.labels(type(exc).__name__).inc()
            # A get cut off mid-request may still complete inside MQ and take a message with it
            # (the REST get is destructive and not transactional); the API's sweeper re-sends
            # the event of any order left "created". Logged so such a loss can be matched up.
            log.warning("get failed (%s: %s); retrying with back-off", type(exc).__name__, exc)
            time.sleep(backoff(failures))
            continue
        if response.status_code == 204:
            failures = 0
            continue  # nothing arrived within the wait
        if response.status_code != 200:
            failures += 1
            GET_ERRORS.labels(f"http {response.status_code}").inc()
            log.warning("get refused: %s %s", response.status_code, response.text[:160])
            time.sleep(backoff(failures))
            continue
        failures = 0

        try:
            event = json.loads(response.text)
            order_id = int(event["order_id"])
        except (ValueError, KeyError, TypeError):
            put(DEAD_LETTER_QUEUE, {"reason": "unreadable", "body": response.text[:500]})
            MESSAGES.labels("dead_lettered").inc()
            log.warning("unreadable message dead-lettered: %s", response.text[:160])
            continue

        attempt = int(event.get("attempt", 1))
        started = time.perf_counter()
        try:
            update = api.put(f"{API_URL}/orders/{order_id}/status", json={"status": "processed"})
            status = update.status_code
        except httpx.HTTPError as exc:
            status = f"{type(exc).__name__}"
        UPDATE_SECONDS.observe(time.perf_counter() - started)
        LAST_EVENT.set_to_current_time()

        if status == 200:
            MESSAGES.labels("processed").inc()
            log.info("order %s processed (event attempt %s)", order_id, attempt)
        elif status == 404:
            put(DEAD_LETTER_QUEUE, {**event, "reason": "order not found"})
            MESSAGES.labels("dead_lettered").inc()
            log.warning("order %s not found; dead-lettered", order_id)
        elif attempt >= MAX_ATTEMPTS:
            put(DEAD_LETTER_QUEUE, {**event, "reason": f"update failed {attempt} times: {status}"})
            MESSAGES.labels("dead_lettered").inc()
            log.warning("order %s dead-lettered after %s attempts (%s)", order_id, attempt, status)
        else:
            time.sleep(backoff(attempt, cap=5))
            if put(QUEUE, {**event, "attempt": attempt + 1}):
                MESSAGES.labels("requeued").inc()
                log.warning("order %s update failed (%s); event put back as attempt %s", order_id, status, attempt + 1)
            else:
                MESSAGES.labels("lost").inc()
                log.error("order %s: update failed and put-back failed; the API sweeper will resend", order_id)
    log.info("worker stopped")


if __name__ == "__main__":
    main()
