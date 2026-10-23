#!/usr/bin/env bash
# Usage: test_mq_trace_context.sh <services directory> <a CA certificate>
# R1.5: the trace crosses IBM MQ in the ibm-mq-usr user property. Runs the given worker and
# orders-api code in their built images, with no network: MQ, orders-api and the database are fakes,
# and the spans are read from an in-memory exporter. The worker's half checks the header parse on
# the shapes MQ was measured to return, that each message is processed under the span that put it,
# that a requeued event's next attempt is a child of the requeue, and that the gets make no span;
# orders-api's half, the send span, the re-send that joins the order's trace, and fail_next.
set -u
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'mq' > "${work}/mq-password"
printf 'pg' > "${work}/postgres-password"
printf 'right-token' > "${work}/worker-token"
printf 'admin-token' > "${work}/admin-token"
cp "$2" "${work}/ca.crt"
chmod 644 "${work}"/*
# As in test_status_auth.sh: the images' UIDs must be able to enter the directory.
chmod 755 "${work}"
services="$(cd "$1" && pwd)"
bad=0

podman run --rm -i --network none --read-only \
  -v "${services}/worker:/srv/worker:ro" -v "${work}:/s:ro" \
  -e MQ_APP_PASSWORD_FILE=/s/mq-password -e WORKER_TOKEN_FILE=/s/worker-token -e PYTHONDONTWRITEBYTECODE=1 \
  localhost/fabric-worker:dev python - <<'PY' || bad=$((bad + $?))
import importlib.util
import json
import logging
import sys

import httpx
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from prometheus_client import REGISTRY
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

exporter = InMemorySpanExporter()
provider = TracerProvider()
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)
spec = importlib.util.spec_from_file_location("worker", "/srv/worker/worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per fake request is noise here

bad = 0


def check(name: str, ok: bool, detail: object = "") -> None:
    global bad
    bad += not ok
    print(f"{'ok' if ok else 'MISMATCH':9} worker: {name}{'  ' + str(detail) if not ok else ''}")


TP = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
# The header exactly as MQ returned it through Envoy for a message with four properties: one header,
# sorted by name, a comma and an escaped quote inside a quoted string (design R1.5, measured).
measured = f'b;true;boolean,l;7;long,q;"x\\",y";string,traceparent;"{TP}";string'
check("MQ's one-header list", worker.mq_properties([measured]) == {"b": "true", "l": "7", "q": 'x",y', "traceparent": TP},
      worker.mq_properties([measured]))
# Should a hop ever send one header per property, get_list keeps them apart; get() would join them.
headers = httpx.Headers([("ibm-mq-usr", 'other;"a,b";string'), ("ibm-mq-usr", f'traceparent;"{TP}";string')])
check("one header per property, through get_list",
      worker.mq_properties(headers.get_list("ibm-mq-usr")) == {"other": "a,b", "traceparent": TP})
check("no header", worker.mq_properties([]) == {})
check("an empty header", worker.mq_properties([""]) == {})
check("garbage", worker.mq_properties(["garbage", "é;;;,,\""]) == {})
check("an unterminated quote", worker.mq_properties([f'traceparent;"{TP};string']) == {})
check("a bad entry keeps those before it",
      worker.mq_properties([f'a;"1";string,%%%,traceparent;"{TP}";string']) == {"a": "1"})


class FakeMQ:
    """One queue per name, in order. A get removes the first message and answers its properties in
    one ibm-mq-usr header, as MQ does; the worker stops once every queue it reads is empty."""

    def __init__(self):
        self.queues: dict[str, list[tuple[str, str, str]]] = {}
        self.ids = 0

    def put(self, queue: str, body: str, usr: str = "") -> str:
        self.ids += 1
        message_id = f"ID:{self.ids:048x}"
        self.queues.setdefault(queue, []).append((message_id, body, usr))
        return message_id

    def __call__(self, request: httpx.Request) -> httpx.Response:
        queue = request.url.path.split("/queue/")[1].split("/")[0]
        if request.method == "POST":
            if queue == "DEV.DEAD.LETTER.QUEUE" and json.loads(request.content) == {
                    "type": "order.created", "order_id": 9, "attempt": 5, "reason": "update failed 5 times: 503"}:
                return httpx.Response(500)  # order 9's dead-letter put fails: the event is lost, and counted so
            message_id = self.put(queue, request.content.decode(), request.headers.get("ibm-mq-usr", ""))
            return httpx.Response(201, headers={"ibm-mq-md-messageId": message_id})
        if not self.queues.get(queue):
            worker.stopping = True
            return httpx.Response(204)
        message_id, body, usr = self.queues[queue].pop(0)
        headers = {"ibm-mq-md-messageId": message_id}
        if usr:
            headers["ibm-mq-usr"] = usr
        return httpx.Response(200, text=body, headers=headers)


mq = FakeMQ()
# The status update fails once for order 1, so its event is requeued (attempt 2) and then processed;
# order 9's last attempt fails, and its dead-letter put too.
answers = {1: [503], 9: [503]}


def fake_api(request: httpx.Request) -> httpx.Response:
    order = int(request.url.path.split("/")[2])
    return httpx.Response(answers.get(order, []).pop(0) if answers.get(order) else 200, json={})


producer = trace.get_tracer("test").start_span("send DEV.QUEUE.1", kind=trace.SpanKind.PRODUCER)
producer.end()
created = producer.get_span_context()
created_tp = f"00-{created.trace_id:032x}-{created.span_id:016x}-01"
mq.put("DEV.QUEUE.1", '{"type": "order.created", "order_id": 1, "attempt": 1}', f'traceparent;"{created_tp}";string')
mq.put("DEV.QUEUE.1", '{"type": "order.created", "order_id": 2, "attempt": 1}')
mq.put("DEV.QUEUE.1", '{"type": "order.created", "order_id": 3, "attempt": 1}', 'traceparent;"00-zz-zz-01";string')
mq.put("DEV.QUEUE.1", "not json", f'traceparent;"{created_tp}";string')
# A body whose attempt is not a number is unreadable too: dead-lettered, and the loop goes on.
mq.put("DEV.QUEUE.1", '{"type": "order.created", "order_id": 4, "attempt": "x"}')
mq.put("DEV.QUEUE.1", '{"type": "order.created", "order_id": 9, "attempt": 5}')

real_client = httpx.Client


def client(*args, **kwargs):
    if "auth" in kwargs:  # the MQ client; instrumented as opentelemetry-instrument does, so a get could make a span
        mq_client = real_client(*args, transport=httpx.MockTransport(mq), **kwargs)
        HTTPXClientInstrumentor.instrument_client(mq_client)
        return mq_client
    return real_client(*args, transport=httpx.MockTransport(fake_api), **kwargs)


worker.httpx.Client = client
worker.start_http_server = lambda *args, **kwargs: None
worker.backoff = lambda *args, **kwargs: 0
worker.main()

spans = exporter.get_finished_spans()
processes = [s for s in spans if s.name == "process DEV.QUEUE.1"]
by_order = {}
for s in processes:
    by_order.setdefault(s.attributes.get("fabric.order.id"), []).append(s)
check("seven messages processed", len(processes) == 7, [s.attributes.get("fabric.order.id") for s in processes])
first, later = by_order.get(1, [None, None])[:2] if len(by_order.get(1, [])) == 2 else (None, None)
check("the process span is a child of the span that put the message",
      first is not None and first.parent is not None and first.parent.span_id == created.span_id
      and first.context.trace_id == created.trace_id and first.kind == trace.SpanKind.CONSUMER)
requeue = [s for s in spans if s.name == "send DEV.QUEUE.1" and s.parent is not None and first is not None
           and s.parent.span_id == first.context.span_id]
check("the failed attempt is an error, its requeue a send span under it",
      first is not None and first.status.status_code == trace.StatusCode.ERROR and len(requeue) == 1
      and requeue[0].kind == trace.SpanKind.PRODUCER)
check("the later attempt is a child of the requeue, in the same trace (AC2)",
      later is not None and len(requeue) == 1 and later.parent.span_id == requeue[0].context.span_id
      and later.context.trace_id == created.trace_id and later.status.status_code == trace.StatusCode.UNSET)
check("no traceparent: a trace of its own", len(by_order.get(2, [])) == 1 and by_order[2][0].parent is None)
check("the process span links to the span that put the message, as the conventions ask",
      first is not None and [link.context.span_id for link in first.links] == [created.span_id]
      and later is not None and len(requeue) == 1
      and [link.context.span_id for link in later.links] == [requeue[0].context.span_id])
check("no traceparent: no link", len(by_order.get(2, [])) == 1 and not by_order[2][0].links)
check("a failed attempt carries error.type, a processed one none",
      first is not None and first.attributes.get("error.type") == "503"
      and later is not None and "error.type" not in later.attributes)
lost = by_order.get(9, [])
check("the last attempt failed and its dead-letter put too: error spans, counted lost",
      len(lost) == 1 and lost[0].status.status_code == trace.StatusCode.ERROR
      and any(s.name == "send DEV.DEAD.LETTER.QUEUE" and s.parent.span_id == lost[0].context.span_id
              and s.attributes.get("error.type") == "500" for s in spans))
check("a malformed traceparent: a trace of its own, processed",
      len(by_order.get(3, [])) == 1 and by_order[3][0].parent is None
      and by_order[3][0].status.status_code == trace.StatusCode.UNSET)
unreadable = [s for s in processes if "fabric.order.id" not in s.attributes]
dead = [s for s in spans if s.name == "send DEV.DEAD.LETTER.QUEUE"]
check("an unreadable message is an error, its dead-letter put a send span under it",
      len(unreadable) == 2 and all(u.status.status_code == trace.StatusCode.ERROR and "error.type" in u.attributes
                                   for u in unreadable)
      and sorted(d.parent.span_id for d in dead if d.parent.span_id in {u.context.span_id for u in unreadable})
      == sorted(u.context.span_id for u in unreadable))
put_back = mq.queues.get("DEV.DEAD.LETTER.QUEUE", [])
want = (f'traceparent;"00-{created.trace_id:032x}-{dead[0].context.span_id:016x}-{dead[0].context.trace_flags:02x}";string'
        if dead else None)
check("the dead-letter message carries its send span's traceparent", len(put_back) == 2 and put_back[0][2] == want,
      put_back)
check("the attributes", first is not None and dict(first.attributes) == {
    "messaging.system": "ibm_mq", "messaging.destination.name": "DEV.QUEUE.1", "messaging.operation.name": "process",
    "messaging.operation.type": "process", "messaging.message.id": f"ID:{1:048x}", "fabric.order.id": 1,
    "error.type": "503"},  # the first attempt, the one that failed
      first and dict(first.attributes))
methods = sorted({s.attributes.get("http.method", s.attributes.get("http.request.method")) for s in spans
                  if s.kind == trace.SpanKind.CLIENT})
check("the gets make no span; the puts do", methods == ["POST"], methods)
outcomes = {result: REGISTRY.get_sample_value("worker_messages_total", {"result": result})
            for result in ("processed", "requeued", "dead_lettered", "lost")}
check("the outcome counters", outcomes == {"processed": 3, "requeued": 1, "dead_lettered": 2, "lost": 1}, outcomes)
print(f"worker mismatches: {bad}")
sys.exit(bad)
PY

podman run --rm -i --network none --read-only \
  -v "${services}/orders-api/app:/srv/app:ro" -v "${work}:/s:ro" \
  -e MQ_REST_URL=http://mqrest.mesh:18080/ibmmq/rest/v3 -e MQ_APP_PASSWORD_FILE=/s/mq-password \
  -e DB_PASSWORD_FILE=/s/postgres-password -e WORKER_TOKEN_FILE=/s/worker-token \
  -e ADMIN_TOKEN_FILE=/s/admin-token -e CA_FILE=/s/ca.crt \
  -e PYTHONDONTWRITEBYTECODE=1 \
  localhost/fabric-orders-api:dev python - <<'PY' || bad=$((bad + $?))
import asyncio
import logging
import sys

import httpx
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

exporter = InMemorySpanExporter()
provider = TracerProvider()
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)
from app import clients, db, main  # noqa: E402 - after the provider, so their tracers record

logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per fake request is noise here

bad = 0


def check(name: str, ok: bool, detail: object = "") -> None:
    global bad
    bad += not ok
    print(f"{'ok' if ok else 'MISMATCH':9} orders-api: {name}{'  ' + str(detail) if not ok else ''}")


answer = {"status": 201}
sent: list[httpx.Request] = []


def fake_mq(request: httpx.Request) -> httpx.Response:
    sent.append(request)
    return httpx.Response(answer["status"], headers={"ibm-mq-md-messageId": "ID:01"})


tracer = trace.get_tracer("test")
order = {"id": 7, "item": "flat white", "quantity": 1, "events_sent": 0, "traceparent": None}


def publish(o: dict) -> tuple[bool, str]:
    exporter.clear()
    sent.clear()
    # A client per run: each asyncio.run is a new event loop.
    clients.mesh = httpx.AsyncClient(transport=httpx.MockTransport(fake_mq))
    return asyncio.run(clients.publish_order_event(o))


def send_span():
    found = [s for s in exporter.get_finished_spans() if s.name == "send DEV.QUEUE.1"]
    return found[0] if len(found) == 1 else None


def traceparent_of(context) -> str:
    return f"00-{context.trace_id:032x}-{context.span_id:016x}-{context.trace_flags:02x}"


def header_of(span) -> str:
    return f'traceparent;"{traceparent_of(span.context)}";string'


# POST /orders: the order row stores the request's traceparent, then the event is sent in the request.
with tracer.start_as_current_span("POST /orders", kind=trace.SpanKind.SERVER) as request:
    order["traceparent"] = clients.current_traceparent()
    result = publish(order)
span = send_span()
check("the order stores its request's traceparent",
      order["traceparent"] == traceparent_of(request.get_span_context()))
check("the put is a send span under the request", result == (True, "") and span is not None
      and span.kind == trace.SpanKind.PRODUCER and span.parent.span_id == request.get_span_context().span_id
      and not span.links)
check("the message carries the send span's traceparent, and nothing else",
      span is not None and len(sent) == 1 and sent[0].headers.get_list("ibm-mq-usr") == [header_of(span)],
      sent and sent[0].headers.get_list("ibm-mq-usr"))
check("the attributes", span is not None and dict(span.attributes) == {
    "messaging.system": "ibm_mq", "messaging.destination.name": "DEV.QUEUE.1", "messaging.operation.name": "send",
    "messaging.operation.type": "send", "fabric.order.id": 7, "messaging.message.id": "ID:01"},
      span and dict(span.attributes))

# The admin's republish: another request, another trace.
with tracer.start_as_current_span("POST /admin/orders/{order_id}/republish", kind=trace.SpanKind.SERVER) as admin:
    publish({**order, "events_sent": 1})
span = send_span()
check("a republish joins the order's trace and links to the admin request",
      span is not None and span.context.trace_id == request.get_span_context().trace_id
      and span.parent.span_id == request.get_span_context().span_id
      and [link.context.span_id for link in span.links] == [admin.get_span_context().span_id])
# The sweeper: no span of its own.
publish({**order, "events_sent": 1})
span = send_span()
check("a sweeper's re-send joins the order's trace, no link",
      span is not None and span.context.trace_id == request.get_span_context().trace_id
      and span.parent.span_id == request.get_span_context().span_id and not span.links)
for name, stored in (("no stored traceparent (an order from before R1.5)", None), ("a malformed one", "00-zz")):
    publish({**order, "traceparent": stored})
    span = send_span()
    check(f"{name}: the re-send starts a trace of its own", span is not None and span.parent is None
          and len(sent) == 1 and sent[0].headers.get("ibm-mq-usr") == header_of(span))

# An order from before R1.5, republished: no stored context, so the send stays in the request's trace.
with tracer.start_as_current_span("POST /admin/orders/{order_id}/republish", kind=trace.SpanKind.SERVER) as admin:
    publish({**order, "traceparent": None})
span = send_span()
check("an order from before R1.5, republished: the send continues the request's trace, no link",
      span is not None and span.parent is not None and span.parent.span_id == admin.get_span_context().span_id
      and not span.links)

# A caller's tracestate (W3C allows ";" in it, which MQ refuses in a property) is not carried.
caller = clients.W3C.extract(
    {"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", "tracestate": "k=a;b"})
with tracer.start_as_current_span("POST /orders", context=caller, kind=trace.SpanKind.SERVER):
    publish(order)
check("a caller's tracestate is not carried",
      len(sent) == 1 and sent[0].headers.get_list("ibm-mq-usr") == [header_of(send_span())],
      sent and sent[0].headers.get_list("ibm-mq-usr"))

answer["status"] = 500
result = publish(order)
check("MQ's refusal: an error span with error.type, the same reason", result == (False, "http 500")
      and send_span() is not None and send_span().status.status_code == trace.StatusCode.ERROR
      and send_span().attributes.get("error.type") == "500")

# fail_next: the next n status updates fail whatever the rate, then updates go through again (here
# to the database check, which no database answers).
from fastapi.testclient import TestClient  # noqa: E402

admin_client, internal = TestClient(main.public), TestClient(main.internal, raise_server_exceptions=False)
chaos = admin_client.put("/admin/chaos", headers={"Authorization": "Bearer admin-token"},
                         json={"fail_rate": 0, "delay_ms": 0, "fail_next": 2})
db.ready.set()
codes = [internal.put("/orders/1/status", headers={"Authorization": "Bearer right-token"},
                      json={"status": "processed"}).status_code for _ in range(3)]
check("fail_next 2: two 503s, then the update goes on", chaos.json() == {"fail_rate": 0.0, "delay_ms": 0, "fail_next": 2}
      and codes[:2] == [503, 503] and codes[2] != 503 and main.chaos["fail_next"] == 0, (chaos.text, codes))
reset = admin_client.put("/admin/chaos", headers={"Authorization": "Bearer admin-token"},
                         json={"fail_rate": 0.5, "delay_ms": 0})
check("a setting without fail_next (phase5's) answers it as 0", reset.json() == {"fail_rate": 0.5, "delay_ms": 0, "fail_next": 0},
      reset.text)
print(f"orders-api mismatches: {bad}")
sys.exit(bad)
PY

echo "mismatches: ${bad}"; exit "${bad}"
