FROM docker.io/library/python:3.12.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
# requirements.lock pins every package with its hash (generated from requirements.txt).
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY tcp_svc.py .

# Fixed non-root UID; the init container gives this UID ownership of /tls/tcp-svc.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 9000 9100
# opentelemetry-instrument (R1.4) configures OpenTelemetry from the OTEL_* variables compose.yaml
# sets, then execs the same command. No library here has an instrumentation, so no spans yet.
CMD ["opentelemetry-instrument", "python", "tcp_svc.py"]
