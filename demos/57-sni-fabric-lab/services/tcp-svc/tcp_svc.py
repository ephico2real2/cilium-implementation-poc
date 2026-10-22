"""tcp-svc: a raw TCP line protocol over TLS, so the lab carries one service that is not HTTP.

Commands, one per line (UTF-8, at most 1024 bytes):
  PING          -> PONG
  TIME          -> the server's time, ISO-8601 UTC
  ECHO <text>   -> <text>
  HELP          -> the command list
  QUIT          -> BYE, then the server closes the connection
Anything else -> "ERR unknown command". The server also closes a connection idle for 60 s.

Prometheus metrics are served over plain HTTP on METRICS_PORT; Envoy's mesh listener is the
only thing that can reach that port.
"""

import asyncio
import datetime
import json
import logging
import os
import signal
import ssl
import sys

from prometheus_client import Counter, Gauge, start_http_server

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9000"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
TLS_DIR = os.environ.get("TLS_DIR", "/tls/tcp-svc")
IDLE_TIMEOUT_S = float(os.environ.get("IDLE_TIMEOUT_S", "60"))
MAX_LINE = 1024
COMMANDS = ("PING", "TIME", "ECHO", "HELP", "QUIT")

CONNECTIONS = Counter("tcp_svc_connections_total", "TLS connections accepted")
ACTIVE = Gauge("tcp_svc_active_connections", "Connections currently open")
COMMANDS_SEEN = Counter("tcp_svc_commands_total", "Commands handled", ["command"])
CLOSED = Counter("tcp_svc_connections_closed_total", "Connections closed, by reason", ["reason"])


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {"ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"), "level": record.levelname,
                 "msg": record.getMessage()}
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("tcp-svc")
log.addHandler(handler)
log.setLevel(logging.INFO)


def reply_to(line: str) -> tuple[str, bool]:
    """Returns the reply for one command line and whether to close the connection."""
    command, _, argument = line.partition(" ")
    command = command.upper()
    if command not in COMMANDS:
        COMMANDS_SEEN.labels("unknown").inc()
        return "ERR unknown command", False
    COMMANDS_SEEN.labels(command.lower()).inc()
    if command == "PING":
        return "PONG", False
    if command == "TIME":
        return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), False
    if command == "ECHO":
        return argument, False
    if command == "HELP":
        return "COMMANDS " + " ".join(COMMANDS), False
    return "BYE", True


async def serve_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    sni = getattr(writer.get_extra_info("ssl_object"), "server_hostname", None)
    CONNECTIONS.inc()
    ACTIVE.inc()
    reason = "client closed"
    log.info("connection opened", extra={"fields": {"peer": str(peer), "sni": sni}})
    try:
        while True:
            try:
                raw = await asyncio.wait_for(reader.readline(), timeout=IDLE_TIMEOUT_S)
            except asyncio.TimeoutError:
                reason = "idle timeout"
                break
            except ValueError:
                # readline() raises ValueError once a line outgrows the stream's limit.
                writer.write(b"ERR line too long\n")
                await writer.drain()
                reason = "line too long"
                break
            if not raw:
                break
            reply, close = reply_to(raw.decode("utf-8", errors="replace").strip())
            writer.write(reply.encode() + b"\n")
            await writer.drain()
            if close:
                reason = "quit"
                break
    except (ConnectionError, ssl.SSLError) as exc:
        reason = type(exc).__name__
    finally:
        CLOSED.labels(reason).inc()
        ACTIVE.dec()
        log.info("connection closed", extra={"fields": {"peer": str(peer), "reason": reason}})
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, ssl.SSLError):
            pass


async def main() -> None:
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(f"{TLS_DIR}/tls.crt", f"{TLS_DIR}/tls.key")
    start_http_server(METRICS_PORT)
    server = await asyncio.start_server(serve_client, "0.0.0.0", LISTEN_PORT, ssl=context,
                                        limit=MAX_LINE + 2)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    log.info("listening", extra={"fields": {"tls_port": LISTEN_PORT, "metrics_port": METRICS_PORT}})
    async with server:
        await stop.wait()
    log.info("stopped")


if __name__ == "__main__":
    asyncio.run(main())
