"""worker: takes order events off MQ and marks each order processed. Every call goes through Envoy.

Loop:
  1. Get one message from DEV.QUEUE.1 through the MQ REST API (Envoy mesh_http -> MQ :9443).
     The REST get is an HTTP DELETE that removes the message: there is no transaction to roll
     back, so Envoy never retries it once sent, and this loop handles every failure after it.
  2. PUT /orders/{id}/status on orders-api (Envoy mesh_http, which retries the idempotent PUT).
  3. If the update still fails, put the event back with attempt + 1; after MAX_ATTEMPTS, put
     it on DEV.DEAD.LETTER.QUEUE. If even the put-back fails, the event is lost here, and the
     API's sweeper sends it again because the order is still "created"; a dead-letter put that
     fails is counted lost too.

Tracing (R1.5): each message is processed in a "process" span whose parent is the span that put
it, read from the message's traceparent user property, so the order is one trace from the API's
POST through the worker's update; every put of the worker's own carries its "send" span the same
way. The get itself makes no span.
"""

import json
import logging
import os
import random
import re
import signal
import sys
import time

import httpx
from opentelemetry import trace
from opentelemetry.instrumentation.utils import suppress_http_instrumentation
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from prometheus_client import Counter, Gauge, Histogram, start_http_server

MQ_REST_URL = os.environ.get("MQ_REST_URL", "http://mqrest.mesh:18080/ibmmq/rest/v3")
MQ_QMGR = os.environ.get("MQ_QMGR", "QM1")
QUEUE = os.environ.get("MQ_QUEUE", "DEV.QUEUE.1")
DEAD_LETTER_QUEUE = os.environ.get("MQ_DEAD_LETTER_QUEUE", "DEV.DEAD.LETTER.QUEUE")
API_URL = os.environ.get("API_URL", "http://api.mesh:18080")
MQ_USER = os.environ.get("MQ_APP_USER", "app")
MQ_PASSWORD_FILE = os.environ.get("MQ_APP_PASSWORD_FILE", "/secrets/worker/mq-app-password")
# orders-api accepts a status update only with this bearer token.
WORKER_TOKEN_FILE = os.environ.get("WORKER_TOKEN_FILE", "/secrets/worker/worker-token")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "5"))
GET_WAIT_MS = int(os.environ.get("GET_WAIT_MS", "5000"))

MESSAGES = Counter("worker_messages_total", "Events handled, by outcome", ["result"])
GET_ERRORS = Counter("worker_get_errors_total", "Failed attempts to get a message", ["reason"])
LAST_EVENT = Gauge("worker_last_event_timestamp_seconds", "When the last event was handled")
UPDATE_SECONDS = Histogram("worker_status_update_seconds", "PUT /orders/{id}/status duration, Envoy retries included",
                           buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))

tracer = trace.get_tracer("worker")
# W3C traceparent only: MQ refuses a property value that holds ";" (MQWB0302E), which tracestate and
# baggage may, so either could make the put itself fail (docs/tracing.md, "Across IBM MQ").
W3C = TraceContextTextMapPropagator()
# One user property of a REST get: name;"string value";string, or name;value;type for other types.
# A string value may hold a comma or an escaped quote (\"), never a semicolon (MQ refuses one).
PROPERTY = re.compile(r'\s*([^;,"\s]+);("(?:[^"\\]|\\.)*"|[^;,"]*);(\w+)\s*(?:,|$)')


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


def mq_properties(headers: list[str]) -> dict[str, str]:
    """A REST get's user properties by name, from its ibm-mq-usr headers (httpx get_list: get()
    would join several with commas). MQ returns every property in one header, joined by commas
    and sorted by name, so the list is split only at commas outside quotes. Reading a header stops
    at the first entry that does not parse: a malformed property costs the properties from it on,
    never the message."""
    properties: dict[str, str] = {}
    for header in headers:
        position = 0
        while position < len(header) and (match := PROPERTY.match(header, position)):
            name, value, kind = match.groups()
            if kind == "string" and value.startswith('"'):
                value = re.sub(r"\\(.)", r"\1", value[1:-1])
            properties[name] = value
            position = match.end()
    return properties


def messaging(queue: str, operation: str) -> dict[str, str]:
    """OpenTelemetry's messaging attributes. IBM MQ has no registered messaging.system value, so
    the name follows the registered ones' form (aws_sqs, gcp_pubsub)."""
    return {"messaging.system": "ibm_mq", "messaging.destination.name": queue,
            "messaging.operation.name": operation, "messaging.operation.type": operation}


def required_secret(path: str) -> str:
    """Read a non-empty secret, or stop before consuming any messages."""
    with open(path, encoding="utf-8") as handle:
        value = handle.read().strip()
    if not value:
        raise RuntimeError(f"required secret is empty: {path}")
    return value


def main() -> None:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Create every outcome's series at 0, so a panel reads 0 rather than "No data" before the
    # first event of that kind.
    for result in ("processed", "requeued", "dead_lettered", "lost"):
        MESSAGES.labels(result)
    mq_password = required_secret(MQ_PASSWORD_FILE)
    worker_token = required_secret(WORKER_TOKEN_FILE)
    start_http_server(METRICS_PORT)
    auth = (MQ_USER, mq_password)
    # The MQ REST API refuses POST and DELETE without this header (any value).
    mq_headers = {"ibm-mq-rest-csrf-token": "fabric"}
    mq = httpx.Client(auth=auth, headers=mq_headers, timeout=httpx.Timeout(GET_WAIT_MS / 1000 + 5, connect=2))
    api_headers = {"Authorization": f"Bearer {worker_token}"}
    api = httpx.Client(headers=api_headers, timeout=httpx.Timeout(15, connect=2))

    def put(queue: str, event: dict) -> bool:
        """Puts one message in a "send" span whose traceparent the message carries: whoever gets it
        continues this trace, so a requeued event's next attempt is a child of this put."""
        with tracer.start_as_current_span(f"send {queue}", kind=SpanKind.PRODUCER,
                                          attributes=messaging(queue, "send")) as span:
            carrier: dict[str, str] = {}
            W3C.inject(carrier)
            headers = {"Content-Type": "text/plain;charset=utf-8"}
            if "traceparent" in carrier:
                headers["ibm-mq-usr"] = f'traceparent;"{carrier["traceparent"]}";string'
            try:
                response = mq.post(queue_url(queue), content=json.dumps(event), headers=headers)
            except httpx.HTTPError as exc:
                # error.type is required on a failed messaging span (the conventions' "recording errors").
                span.set_attribute("error.type", type(exc).__name__)
                span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
                log.warning("put to %s failed: %s", queue, exc)
                return False
            if response.status_code == 201:
                span.set_attribute("messaging.message.id", response.headers.get("ibm-mq-md-messageId", ""))
                return True
            span.set_attribute("error.type", str(response.status_code))
            span.set_status(Status(StatusCode.ERROR, f"http {response.status_code}"))
            return False

    def dead_letter(event: dict) -> str:
        """Puts an event on the dead-letter queue; returns the outcome it counted: "dead_lettered", or
        "lost" if the put failed."""
        outcome = "dead_lettered" if put(DEAD_LETTER_QUEUE, event) else "lost"
        MESSAGES.labels(outcome).inc()
        return outcome

    log.info("worker started: %s -> %s", queue_url(QUEUE), API_URL)
    failures = 0
    while not stopping:
        try:
            # No span for the get: an empty long poll every GET_WAIT_MS would be a trace of its own
            # (115 of the worker's 116 traces in 10 idle minutes); the processing below is traced.
            with suppress_http_instrumentation():
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

        # The parent is the span that put the message, and the span links to it too: the messaging
        # conventions ask every "process" span to link to its message's creation context, and allow
        # it as the parent. A message without a valid traceparent (put before R1.5, or by hand)
        # starts a trace of its own, with no link.
        created_in = W3C.extract(mq_properties(response.headers.get_list("ibm-mq-usr")))
        creation = trace.get_current_span(created_in).get_span_context()
        with tracer.start_as_current_span(
                f"process {QUEUE}", context=created_in, kind=SpanKind.CONSUMER,
                links=[trace.Link(creation)] if creation.is_valid else [],
                attributes={**messaging(QUEUE, "process"),
                            "messaging.message.id": response.headers.get("ibm-mq-md-messageId", "")}) as span:
            try:
                event = json.loads(response.text)
                order_id = int(event["order_id"])
                attempt = int(event.get("attempt", 1))
            except (ValueError, KeyError, TypeError) as exc:
                outcome = dead_letter({"reason": "unreadable", "body": response.text[:500]})
                span.set_attribute("error.type", type(exc).__name__)
                span.set_status(Status(StatusCode.ERROR, "unreadable"))
                log.warning("unreadable message %s: %s", outcome.replace("_", "-"), response.text[:160])
                continue
            span.set_attribute("fabric.order.id", order_id)

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
                outcome = dead_letter({**event, "reason": "order not found"})
                log.warning("order %s not found; %s", order_id, outcome.replace("_", "-"))
            elif attempt >= MAX_ATTEMPTS:
                outcome = dead_letter({**event, "reason": f"update failed {attempt} times: {status}"})
                log.warning("order %s %s after %s attempts (%s)", order_id, outcome.replace("_", "-"), attempt, status)
            else:
                time.sleep(backoff(attempt, cap=5))
                if put(QUEUE, {**event, "attempt": attempt + 1}):
                    MESSAGES.labels("requeued").inc()
                    log.warning("order %s update failed (%s); event put back as attempt %s", order_id, status, attempt + 1)
                else:
                    MESSAGES.labels("lost").inc()
                    log.error("order %s: update failed and put-back failed; the API sweeper will resend", order_id)
            if status != 200:
                span.set_attribute("error.type", str(status))
                span.set_status(Status(StatusCode.ERROR, f"update failed (attempt {attempt}): {status}"))
    log.info("worker stopped")


if __name__ == "__main__":
    main()
